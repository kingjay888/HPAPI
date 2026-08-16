from __future__ import annotations

import asyncio
import logging
import re
import time
from pathlib import Path
from typing import Any

import httpx

from .config import settings

logger = logging.getLogger(__name__)

IMAGE_URL_PATTERN = re.compile(
    r"https://ssl-product-images\.www8-hp\.com/[^\s\"'<>]+",
    re.IGNORECASE,
)


def _cert_tuple() -> tuple[str, str] | None:
    cert_path = settings.hp_catalog_client_cert
    if not cert_path:
        return None

    cert_file = Path(cert_path)
    if not cert_file.is_file():
        return None

    key_path = settings.hp_catalog_client_key
    if key_path:
        key_file = Path(key_path)
        if key_file.is_file():
            return str(cert_file), str(key_file)

    return str(cert_file), str(cert_file)


def _auth_tuple() -> tuple[str, str] | None:
    """Credentials for httpx's `auth=` argument. Only used in 'basic' mode."""
    if settings.hp_catalog_auth_mode != "basic":
        return None
    if settings.hp_catalog_client_id and settings.hp_catalog_client_secret:
        return settings.hp_catalog_client_id, settings.hp_catalog_client_secret
    return None


# Cached OAuth2 access token: (token, expires_at_monotonic).
_token_cache: tuple[str, float] | None = None
_token_lock = asyncio.Lock()


async def _get_oauth_token(client: httpx.AsyncClient) -> str | None:
    """Fetch and cache a client_credentials access token.

    Cached because products are looked up concurrently — without this, every
    product in a batch would mint its own token.
    """
    global _token_cache

    if not settings.hp_catalog_token_url:
        logger.error("HP_CATALOG_AUTH_MODE=oauth2 but HP_CATALOG_TOKEN_URL is not set")
        return None

    async with _token_lock:
        now = time.monotonic()
        if _token_cache and _token_cache[1] > now + 30:
            return _token_cache[0]

        data = {"grant_type": "client_credentials"}
        if settings.hp_catalog_oauth_scope:
            data["scope"] = settings.hp_catalog_oauth_scope

        try:
            response = await client.post(
                settings.hp_catalog_token_url,
                data=data,
                auth=(settings.hp_catalog_client_id, settings.hp_catalog_client_secret),
                headers={"Accept": "application/json"},
            )
        except (httpx.HTTPError, OSError) as exc:
            logger.error("token request failed: %s %s", type(exc).__name__, exc)
            return None

        if response.status_code >= 400:
            logger.error(
                "token endpoint returned HTTP %s: %s",
                response.status_code, response.text.strip()[:200],
            )
            return None

        try:
            payload = response.json()
        except ValueError:
            logger.error("token endpoint did not return JSON")
            return None

        token = payload.get("access_token") or payload.get("accessToken") or payload.get("token")
        if not token:
            logger.error("token endpoint response had no access_token field")
            return None

        try:
            lifetime = float(payload.get("expires_in", 3600))
        except (TypeError, ValueError):
            lifetime = 3600.0

        _token_cache = (token, time.monotonic() + lifetime)
        logger.info("obtained catalog access token, valid %.0fs", lifetime)
        return token


async def _auth_headers(client: httpx.AsyncClient) -> dict[str, str]:
    """Auth headers for the configured mode. Empty dict for 'basic'."""
    mode = settings.hp_catalog_auth_mode

    if mode == "basic":
        return {}

    if mode == "bearer":
        value = settings.hp_catalog_api_key_value or settings.hp_catalog_client_secret
        return {"Authorization": f"Bearer {value}"} if value else {}

    if mode == "apikey":
        value = settings.hp_catalog_api_key_value or settings.hp_catalog_client_id
        return {settings.hp_catalog_api_key_header: value} if value else {}

    if mode == "oauth2":
        token = await _get_oauth_token(client)
        return {"Authorization": f"Bearer {token}"} if token else {}

    logger.error("unknown HP_CATALOG_AUTH_MODE=%r; falling back to basic", mode)
    return {}


def _build_request_body(product_number: str) -> dict[str, Any]:
    return {
        "requestContext": {
            "requesterId": settings.catalog_requester_id,
            "countryCode": settings.hp_country_code,
            "languageCode": settings.hp_language_code,
        },
        "productNumbers": [product_number],
        "products": [{"productNumber": product_number}],
    }


def _extract_images_from_payload(payload: Any) -> list[dict[str, str]]:
    images: list[dict[str, str]] = []
    seen: set[str] = set()

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            url = (
                node.get("image_url_https")
                or node.get("imageUrlHttps")
                or node.get("imageUrl")
                or node.get("image_url")
                or node.get("url")
            )
            if isinstance(url, str) and "ssl-product-images" in url.lower():
                if url not in seen:
                    seen.add(url)
                    images.append(
                        {
                            "url": url,
                            "label": str(
                                node.get("imageType")
                                or node.get("type")
                                or node.get("name")
                                or "Product image"
                            ),
                        }
                    )
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)
        elif isinstance(node, str):
            for match in IMAGE_URL_PATTERN.findall(node):
                if match not in seen:
                    seen.add(match)
                    images.append({"url": match, "label": "Product image"})

    walk(payload)
    return images


async def fetch_catalog_images(
    client: httpx.AsyncClient,
    product_number: str,
) -> dict[str, Any]:
    if not settings.catalog_configured:
        return {
            "found": False,
            "images": [],
            "error": "HP Catalog Service API is not configured.",
        }

    cert = _cert_tuple()
    auth = _auth_tuple()
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    headers.update(await _auth_headers(client))

    body = _build_request_body(product_number)
    # POST targets under HP_CATALOG_BASE_URL, e.g.
    #   https://hpit-gw.hpcloud.hp.com/generic-router/api/hermes/images
    #   https://hpit-gw.hpcloud.hp.com/generic-router/api/hermes/productcontent
    endpoints = ("images", "productcontent")

    # Every endpoint attempt records why it failed. Without this the caller only
    # ever saw "No images returned", which cannot distinguish bad credentials
    # (401) from a wrong URL (404) from a network block (timeout).
    attempts: list[str] = []

    async def _try_endpoints(http_client: httpx.AsyncClient) -> dict[str, Any] | None:
        for endpoint in endpoints:
            url = f"{settings.hp_catalog_base_url.rstrip('/')}/{endpoint}"
            try:
                response = await http_client.post(
                    url,
                    json=body,
                    headers=headers,
                    auth=auth,
                )
                if response.status_code >= 400:
                    detail = response.text.strip().replace("\n", " ")[:200]
                    attempts.append(f"{endpoint}: HTTP {response.status_code} {detail}".rstrip())
                    logger.warning("catalog %s -> HTTP %s: %s", url, response.status_code, detail)
                    continue

                try:
                    payload = response.json()
                except ValueError:
                    attempts.append(
                        f"{endpoint}: HTTP {response.status_code} but body was not JSON"
                    )
                    continue

                images = _extract_images_from_payload(payload)
                if images:
                    return {
                        "found": True,
                        "images": images,
                        "source": f"hp_catalog:{endpoint}",
                        "product_number": product_number,
                    }
                attempts.append(f"{endpoint}: HTTP {response.status_code} but no image URLs in response")
            except (httpx.HTTPError, OSError) as exc:
                # httpx timeout exceptions stringify to "", so include the type.
                attempts.append(f"{endpoint}: {type(exc).__name__} {exc}".rstrip())
                logger.warning("catalog %s failed: %s %s", url, type(exc).__name__, exc)
                continue
        return None

    if cert:
        async with httpx.AsyncClient(timeout=client.timeout, cert=cert) as catalog_client:
            result = await _try_endpoints(catalog_client)
    else:
        result = await _try_endpoints(client)

    if result:
        return result

    detail = "; ".join(attempts) if attempts else "no endpoints attempted"
    return {
        "found": False,
        "images": [],
        "error": f"HP Catalog Service API returned no images ({detail}).",
        "product_number": product_number,
    }
