from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import httpx

from .config import settings

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
    if settings.hp_catalog_client_id and settings.hp_catalog_client_secret:
        return settings.hp_catalog_client_id, settings.hp_catalog_client_secret
    return None


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

    body = _build_request_body(product_number)
    endpoints = ("images", "productcontent")

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
                    continue

                payload = response.json()
                images = _extract_images_from_payload(payload)
                if images:
                    return {
                        "found": True,
                        "images": images,
                        "source": f"hp_catalog:{endpoint}",
                        "product_number": product_number,
                    }
            except (httpx.HTTPError, OSError):
                continue
        return None

    if cert:
        async with httpx.AsyncClient(timeout=client.timeout, cert=cert) as catalog_client:
            result = await _try_endpoints(catalog_client)
    else:
        result = await _try_endpoints(client)

    if result:
        return result

    return {
        "found": False,
        "images": [],
        "error": "No images returned from HP Catalog Service API.",
        "product_number": product_number,
    }
