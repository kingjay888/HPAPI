from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

import httpx

from .config import settings
from .hp_catalog import fetch_catalog_images
from .hp_partsurfer import lookup_product
from .hp_shop import fetch_shop_images

logger = logging.getLogger(__name__)


def _result(
    query: str,
    product_number: str,
    product_name: str | None,
    *,
    found: bool,
    images: list[dict[str, str]],
    source: str | None,
    lookup: dict[str, Any],
    errors: list[str] | None = None,
    message: str | None = None,
    elapsed: float | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "input": query,
        "product_number": product_number,
        "product_name": product_name,
        "found": found,
        "images": images,
        "source": source,
        "lookup": lookup,
    }
    if errors:
        payload["errors"] = errors
    if message:
        payload["message"] = message
    if elapsed is not None:
        payload["elapsed_seconds"] = round(elapsed, 2)
    return payload


async def fetch_product_images(
    client: httpx.AsyncClient,
    query: str,
) -> dict[str, Any]:
    started = time.monotonic()

    lookup = await lookup_product(client, query)
    product_number = lookup.get("product_number") or query
    product_name = lookup.get("product_name")

    errors: list[str] = []

    if settings.catalog_configured:
        catalog_result = await fetch_catalog_images(client, product_number)
        if catalog_result.get("found"):
            return _result(
                query, product_number, product_name,
                found=True,
                images=catalog_result["images"],
                source=catalog_result["source"],
                lookup=lookup,
                elapsed=time.monotonic() - started,
            )
        if catalog_result.get("error"):
            errors.append(str(catalog_result["error"]))
    else:
        errors.append(
            "HP Catalog Service API is not configured "
            "(set HP_CATALOG_CLIENT_ID and HP_CATALOG_CLIENT_SECRET)."
        )

    if settings.hp_shop_enabled:
        shop_result = await fetch_shop_images(client, product_number, product_name)
        if shop_result.get("found"):
            return _result(
                query, product_number, product_name,
                found=True,
                images=shop_result["images"],
                source=shop_result["source"],
                lookup=lookup,
                elapsed=time.monotonic() - started,
            )
        if shop_result.get("error"):
            errors.append(str(shop_result["error"]))
    else:
        errors.append("HP Shop fallback is disabled (HP_SHOP_ENABLED=false).")

    return _result(
        query, product_number, product_name,
        found=False,
        images=[],
        source=None,
        lookup=lookup,
        errors=errors,
        message=(
            "No images found. Configure HP Catalog Service API credentials for best results, "
            "or verify the product number and try again."
        ),
        elapsed=time.monotonic() - started,
    )


async def _fetch_one_guarded(
    client: httpx.AsyncClient,
    semaphore: asyncio.Semaphore,
    query: str,
) -> dict[str, Any]:
    """Run one product lookup under a concurrency limit and a hard deadline.

    A single unresponsive upstream must never be able to stall the whole batch:
    without the deadline, one product that hangs holds the HTTP response open
    until the browser or a proxy in between gives up, which surfaces to the user
    as an opaque "Failed to fetch".
    """
    async with semaphore:
        started = time.monotonic()
        try:
            return await asyncio.wait_for(
                fetch_product_images(client, query),
                timeout=settings.product_timeout_seconds,
            )
        except asyncio.TimeoutError:
            logger.warning("product %s timed out after %.1fs", query, settings.product_timeout_seconds)
            return _result(
                query, query, None,
                found=False,
                images=[],
                source=None,
                lookup={"found": False, "query": query},
                errors=[f"Timed out after {settings.product_timeout_seconds:.0f}s."],
                message="Lookup timed out. HP did not respond in time for this product.",
                elapsed=time.monotonic() - started,
            )
        except Exception as exc:  # noqa: BLE001 - one bad product must not fail the batch
            logger.exception("product %s failed", query)
            return _result(
                query, query, None,
                found=False,
                images=[],
                source=None,
                lookup={"found": False, "query": query},
                errors=[f"{type(exc).__name__}: {exc}"],
                message="Lookup failed for this product.",
                elapsed=time.monotonic() - started,
            )


async def fetch_many_products(products: list[str]) -> list[dict[str, Any]]:
    """Look up every product concurrently, preserving input order.

    Previously this looped sequentially, so total time was the sum of every
    product's worst case — enough to blow past proxy and browser limits on even
    a handful of items.
    """
    timeout = httpx.Timeout(settings.request_timeout_seconds)
    limits = httpx.Limits(
        max_connections=max(settings.max_concurrency * 2, 10),
        max_keepalive_connections=settings.max_concurrency,
    )
    semaphore = asyncio.Semaphore(max(settings.max_concurrency, 1))

    started = time.monotonic()
    async with httpx.AsyncClient(timeout=timeout, limits=limits) as client:
        # gather preserves ordering of the input list regardless of finish order.
        results = await asyncio.gather(
            *(_fetch_one_guarded(client, semaphore, product) for product in products)
        )

    logger.info(
        "looked up %d products in %.1fs (concurrency=%d)",
        len(products), time.monotonic() - started, settings.max_concurrency,
    )
    return list(results)
