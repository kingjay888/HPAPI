from __future__ import annotations

import json
import re
from typing import Any
from urllib.parse import quote

import httpx

from .config import settings
from .hp_catalog import IMAGE_URL_PATTERN

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}


def _unique_images(urls: list[str]) -> list[dict[str, str]]:
    seen: set[str] = set()
    images: list[dict[str, str]] = []
    for url in urls:
        if url in seen:
            continue
        seen.add(url)
        images.append({"url": url, "label": "HP Shop image"})
    return images


def _extract_images_from_html(html: str) -> tuple[list[dict[str, str]], list[str]]:
    urls: list[str] = []

    for match in IMAGE_URL_PATTERN.findall(html):
        urls.append(match.split("?")[0] if "?" in match else match)

    og_matches = re.findall(
        r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)["\']',
        html,
        flags=re.IGNORECASE,
    )
    urls.extend(og_matches)

    json_ld_blocks = re.findall(
        r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    for block in json_ld_blocks:
        try:
            data = json.loads(block)
        except json.JSONDecodeError:
            continue
        walk = [data]
        while walk:
            node = walk.pop()
            if isinstance(node, dict):
                image = node.get("image")
                if isinstance(image, str):
                    urls.append(image)
                elif isinstance(image, list):
                    urls.extend(item for item in image if isinstance(item, str))
                walk.extend(node.values())
            elif isinstance(node, list):
                walk.extend(node)

    pdp_links = re.findall(r'href=["\'](/us-en/shop/pdp/[^"\']+)["\']', html)
    return _unique_images(urls), pdp_links


async def fetch_shop_images(
    client: httpx.AsyncClient,
    product_number: str,
    product_name: str | None = None,
) -> dict[str, Any]:
    search_term = product_number or product_name or ""
    search_url = (
        f"{settings.hp_shop_base_url.rstrip('/')}/search-results.html"
        f"?searchTerm={quote(search_term)}"
    )

    try:
        response = await client.get(search_url, headers=BROWSER_HEADERS, follow_redirects=True)
        response.raise_for_status()
    except httpx.HTTPError as exc:
        return {
            "found": False,
            "images": [],
            "error": f"HP Shop search failed: {exc}",
        }

    images, pdp_links = _extract_images_from_html(response.text)

    if not images and pdp_links:
        pdp_path = pdp_links[0]
        pdp_url = pdp_path if pdp_path.startswith("http") else f"https://www.hp.com{pdp_path}"
        try:
            pdp_response = await client.get(pdp_url, headers=BROWSER_HEADERS, follow_redirects=True)
            pdp_response.raise_for_status()
            images, _ = _extract_images_from_html(pdp_response.text)
        except httpx.HTTPError:
            pass

    if images:
        return {
            "found": True,
            "images": images,
            "source": "hp_shop",
            "product_number": product_number,
        }

    return {
        "found": False,
        "images": [],
        "error": "No product images found on HP Shop.",
        "product_number": product_number,
    }
