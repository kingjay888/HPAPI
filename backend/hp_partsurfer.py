from __future__ import annotations

import json
from typing import Any
from urllib.parse import quote

import httpx

from .config import settings

PARTSURFER_HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; HPPrinterImageFetcher/1.0)",
    "Accept": "application/json",
    "Origin": "https://partsurfer.hp.com",
    "Referer": "https://partsurfer.hp.com/",
}


def _proxy_url(path: str) -> str:
    return f"{settings.partsurfer_bff_url}/proxy/get?input={quote(path, safe='')}"


async def _get_json(client: httpx.AsyncClient, path: str) -> dict[str, Any]:
    response = await client.get(_proxy_url(path), headers=PARTSURFER_HEADERS)
    response.raise_for_status()
    return response.json()


def _extract_product_name(payload: dict[str, Any]) -> str | None:
    body = payload.get("Body")
    if not isinstance(body, dict):
        return None

    product_list = body.get("ProductNameList")
    if isinstance(product_list, list) and product_list:
        first = product_list[0]
        if isinstance(first, dict):
            return first.get("ProductName") or first.get("productName")

    product_bom = body.get("ProductBOM")
    if isinstance(product_bom, list) and product_bom:
        first = product_bom[0]
        if isinstance(first, dict):
            return first.get("ProductName") or first.get("productName")

    return None


def _extract_resolved_product_number(payload: dict[str, Any]) -> str | None:
    body = payload.get("Body")
    if not isinstance(body, dict):
        return None

    product_list = body.get("ProductNameList")
    if isinstance(product_list, list) and product_list:
        first = product_list[0]
        if isinstance(first, dict):
            return first.get("ProductNumber") or first.get("productNumber")

    product_bom = body.get("ProductBOM")
    if isinstance(product_bom, list) and product_bom:
        first = product_bom[0]
        if isinstance(first, dict):
            return first.get("ProductNumber") or first.get("productNumber")

    return None


async def lookup_product(
    client: httpx.AsyncClient,
    query: str,
    country: str | None = None,
) -> dict[str, Any]:
    country_code = country or settings.hp_country_code
    encoded_query = quote(query.strip(), safe="")
    path = f"/Search/GenericSearch/{encoded_query}/country/{country_code}/usertype/Guest"

    try:
        payload = await _get_json(client, path)
    except httpx.HTTPError as exc:
        return {
            "found": False,
            "query": query,
            "error": str(exc),
        }

    status = payload.get("Status", {})
    code = status.get("Code", "")
    product_name = _extract_product_name(payload)
    product_number = _extract_resolved_product_number(payload) or query
    found = bool(product_name) and code not in {"E-0001"}

    return {
        "found": found,
        "query": query,
        "product_number": product_number,
        "product_name": product_name,
        "source": "partsurfer",
        "status_code": code,
        "raw_status": status.get("Message"),
    }
