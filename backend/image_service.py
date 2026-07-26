from __future__ import annotations

from typing import Any

import httpx

from .config import settings
from .hp_catalog import fetch_catalog_images
from .hp_partsurfer import lookup_product
from .hp_shop import fetch_shop_images


async def fetch_product_images(
    client: httpx.AsyncClient,
    query: str,
) -> dict[str, Any]:
    lookup = await lookup_product(client, query)
    product_number = lookup.get("product_number") or query
    product_name = lookup.get("product_name")

    errors: list[str] = []

    if settings.catalog_configured:
        catalog_result = await fetch_catalog_images(client, product_number)
        if catalog_result.get("found"):
            return {
                "input": query,
                "product_number": product_number,
                "product_name": product_name,
                "found": True,
                "images": catalog_result["images"],
                "source": catalog_result["source"],
                "lookup": lookup,
            }
        if catalog_result.get("error"):
            errors.append(str(catalog_result["error"]))

    shop_result = await fetch_shop_images(client, product_number, product_name)
    if shop_result.get("found"):
        return {
            "input": query,
            "product_number": product_number,
            "product_name": product_name,
            "found": True,
            "images": shop_result["images"],
            "source": shop_result["source"],
            "lookup": lookup,
        }
    if shop_result.get("error"):
        errors.append(str(shop_result["error"]))

    return {
        "input": query,
        "product_number": product_number,
        "product_name": product_name,
        "found": False,
        "images": [],
        "source": None,
        "lookup": lookup,
        "errors": errors,
        "message": (
            "No images found. Configure HP Catalog Service API credentials for best results, "
            "or verify the product number and try again."
        ),
    }


async def fetch_many_products(products: list[str]) -> list[dict[str, Any]]:
    timeout = httpx.Timeout(settings.request_timeout_seconds)
    results: list[dict[str, Any]] = []

    async with httpx.AsyncClient(timeout=timeout) as client:
        for product in products:
            results.append(await fetch_product_images(client, product))

    return results
