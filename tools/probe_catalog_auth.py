#!/usr/bin/env python3
"""Work out what authentication the HP Catalog gateway actually wants.

The gateway answers Basic auth with `401 {"error": "Invalid token."}`. That
wording — "token", not "credentials" — says it is looking for a bearer token or
an API key, not an Authorization: Basic header. Rather than guess, this probes
each plausible scheme and reports what comes back.

Run it on the instance:

    cd ~/HPAPI
    sudo -u ubuntu .venv/bin/python tools/probe_catalog_auth.py

It reads credentials from /etc/hp-printer-images/app.env when present, else the
repo's .env. Nothing is written and no credential is ever printed in full.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import os
import re
import sys
from pathlib import Path

import httpx

DEFAULT_ENV_FILES = [
    Path("/etc/hp-printer-images/app.env"),
    Path(__file__).resolve().parent.parent / ".env",
]

# Apigee-style gateways expose their token endpoint at one of these.
TOKEN_URL_CANDIDATES = [
    "https://hpit-gw.hpcloud.hp.com/oauth/token",
    "https://hpit-gw.hpcloud.hp.com/oauth2/token",
    "https://hpit-gw.hpcloud.hp.com/oauth2/v1/token",
    "https://hpit-gw.hpcloud.hp.com/v1/oauth/token",
    "https://hpit-gw.hpcloud.hp.com/token",
    "https://hpit-gw.hpcloud.hp.com/generic-router/oauth/token",
    "https://hpit-gw.hpcloud.hp.com/generic-router/api/oauth/token",
]


def load_env(explicit: str | None) -> dict[str, str]:
    """Parse a KEY=value file, tolerating systemd's quoted-value form."""
    files = [Path(explicit)] if explicit else DEFAULT_ENV_FILES
    for path in files:
        if not path.is_file():
            continue
        try:
            raw = path.read_text()
        except PermissionError:
            print(f"  (cannot read {path} — try sudo)", file=sys.stderr)
            continue
        data: dict[str, str] = {}
        for line in raw.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] == '"':
                value = value[1:-1]
                value = re.sub(r'\\(.)', r'\1', value)
            data[key.strip()] = value
        print(f"Loaded credentials from {path}")
        return data
    print("ERROR: no env file found. Pass --env-file PATH.", file=sys.stderr)
    sys.exit(1)


def mask(value: str) -> str:
    if not value:
        return "(empty)"
    return f"{value[:4]}…{value[-2:]} ({len(value)} chars)"


def classify(status: int, body: str) -> tuple[str, bool]:
    """Return (description, credential_was_accepted).

    Careful with 400 here. This gateway answers a request carrying NO
    Authorization header with `400 {"error": "JWT Token is required."}` — that
    is a rejection, not progress. An earlier version of this script treated
    "anything but 401" as acceptance and so reported api-key headers (and even
    sending no credentials at all) as working. They were simply being ignored.
    """
    lowered = body.lower()
    if "jwt token is required" in lowered:
        return "no JWT sent (credential ignored)", False
    if status == 401:
        return "rejected", False
    if status == 400:
        return "bad request", False
    if status == 403:
        return "authenticated, not authorised", True
    if status == 404:
        return "auth OK, wrong path", True
    if 200 <= status < 300:
        return "*** ACCEPTED ***", True
    return "other", False


async def try_request(
    client: httpx.AsyncClient,
    label: str,
    url: str,
    headers: dict[str, str],
    body: dict,
    auth: tuple[str, str] | None = None,
) -> bool:
    """POST once and report. Returns True only if the credential was accepted."""
    try:
        response = await client.post(url, json=body, headers=headers, auth=auth)
    except httpx.HTTPError as exc:
        detail = str(exc).strip() or type(exc).__name__
        print(f"  {label:38} -> ERROR {detail}")
        return False
    text = response.text.strip().replace("\n", " ")
    description, accepted = classify(response.status_code, text)
    print(f"  {label:38} -> {response.status_code} {description:30} {text[:100]}")
    return accepted


async def probe_token_endpoints(
    client: httpx.AsyncClient, client_id: str, client_secret: str
) -> str | None:
    print("\n=== OAuth2 client_credentials token endpoints ===")
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    for url in TOKEN_URL_CANDIDATES:
        for label, kwargs in (
            (
                "Basic header + grant in body",
                {
                    "headers": {
                        "Authorization": f"Basic {basic}",
                        "Content-Type": "application/x-www-form-urlencoded",
                    },
                    "data": {"grant_type": "client_credentials"},
                },
            ),
            (
                "credentials in body",
                {
                    "headers": {"Content-Type": "application/x-www-form-urlencoded"},
                    "data": {
                        "grant_type": "client_credentials",
                        "client_id": client_id,
                        "client_secret": client_secret,
                    },
                },
            ),
        ):
            try:
                response = await client.post(url, **kwargs)
            except httpx.HTTPError as exc:
                detail = str(exc).strip() or type(exc).__name__
                print(f"  {url}\n    {label:32} -> ERROR {detail}")
                continue

            snippet = response.text.strip().replace("\n", " ")[:110]
            print(f"  {url}\n    {label:32} -> {response.status_code} {snippet}")

            if 200 <= response.status_code < 300:
                try:
                    payload = response.json()
                except ValueError:
                    continue
                token = (
                    payload.get("access_token")
                    or payload.get("accessToken")
                    or payload.get("token")
                )
                if token:
                    print(f"\n  *** GOT A TOKEN from {url} ({label}) ***")
                    print(f"      token: {mask(token)}")
                    return token
    return None


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", help="path to a KEY=value file")
    parser.add_argument("--product", default="2Z599F", help="product number to test with")
    args = parser.parse_args()

    env = load_env(args.env_file)
    base = env.get(
        "HP_CATALOG_BASE_URL", "https://hpit-gw.hpcloud.hp.com/generic-router/api/hermes"
    ).rstrip("/")
    client_id = env.get("HP_CATALOG_CLIENT_ID", "")
    client_secret = env.get("HP_CATALOG_CLIENT_SECRET", "")
    requester = env.get("HP_CATALOG_REQUESTER_ID", "") or client_id
    country = env.get("HP_COUNTRY_CODE", "US")
    language = env.get("HP_LANGUAGE_CODE", "en")

    print(f"Base URL:      {base}")
    print(f"Client ID:     {mask(client_id)}")
    print(f"Client secret: {mask(client_secret)}")
    if not client_id or not client_secret:
        print("\nERROR: client id/secret missing from the env file.", file=sys.stderr)
        return 1

    body = {
        "requestContext": {
            "requesterId": requester,
            "countryCode": country,
            "languageCode": language,
        },
        "productNumbers": [args.product],
        "products": [{"productNumber": args.product}],
    }
    json_headers = {"Accept": "application/json", "Content-Type": "application/json"}
    url = f"{base}/images"

    timeout = httpx.Timeout(20.0)
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
        print(f"\n=== Direct auth schemes against {url} ===")
        print("  (401 = rejected; 403/404 = the credential was accepted)\n")

        schemes: list[tuple[str, dict[str, str], tuple[str, str] | None]] = [
            ("Basic (what the app does now)", dict(json_headers), (client_id, client_secret)),
            ("Bearer <client_secret>", {**json_headers, "Authorization": f"Bearer {client_secret}"}, None),
            ("Bearer <client_id>", {**json_headers, "Authorization": f"Bearer {client_id}"}, None),
            ("x-api-key: <client_id>", {**json_headers, "x-api-key": client_id}, None),
            ("x-api-key: <client_secret>", {**json_headers, "x-api-key": client_secret}, None),
            ("apikey: <client_id>", {**json_headers, "apikey": client_id}, None),
            ("apikey: <client_secret>", {**json_headers, "apikey": client_secret}, None),
            ("client_id + client_secret headers",
             {**json_headers, "client_id": client_id, "client_secret": client_secret}, None),
            ("X-HP-Client-Id + Secret headers",
             {**json_headers, "X-HP-Client-Id": client_id, "X-HP-Client-Secret": client_secret}, None),
            ("no auth at all", dict(json_headers), None),
        ]

        accepted: list[str] = []
        for label, headers, auth in schemes:
            if await try_request(client, label, url, headers, body, auth):
                accepted.append(label)

        token = await probe_token_endpoints(client, client_id, client_secret)
        if token:
            print("\n=== Retrying the API with that OAuth token ===")
            if await try_request(
                client,
                "Bearer <oauth access_token>",
                url,
                {**json_headers, "Authorization": f"Bearer {token}"},
                body,
            ):
                accepted.append("OAuth2 bearer token")

        print("\n" + "=" * 72)
        if accepted:
            print("Schemes the gateway ACCEPTED:")
            for item in accepted:
                print(f"  - {item}")
            print("\nSet HP_CATALOG_AUTH_MODE in .env to match, then re-run 01-put-secrets.sh.")
        else:
            print("No scheme was accepted.")
            print()
            print("If the failures split like this:")
            print('  - Authorization header sent  -> 401 "Invalid token."')
            print('  - no Authorization header    -> 400 "JWT Token is required."')
            print()
            print("then the gateway wants a JWT bearer token, and your client id and")
            print("secret are NOT that token — they have to be exchanged for one at an")
            print("identity provider that is not hosted on this gateway.")
            print()
            print("Run tools/probe_catalog_jwt.py next to look for the issuer.")
        print("=" * 72)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
