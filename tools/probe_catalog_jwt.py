#!/usr/bin/env python3
"""Find out WHICH JWT the HP catalog gateway wants.

The first probe established the gateway's behaviour:

    Authorization header present  ->  401 {"error": "Invalid token."}
    Authorization header absent   ->  400 {"error": "JWT Token is required."}

So it parses a bearer JWT and nothing else — api-key headers are ignored
outright. The client id and secret are not themselves the token; they must be
exchanged for a JWT at an identity provider that is NOT on this gateway (every
token path there 404s).

This script tries to identify that issuer without guessing blindly:

  1. Dumps every response header on a 401 and a 400. Gateways routinely name the
     issuer or realm in WWW-Authenticate.
  2. Tries OIDC discovery documents on the gateway and related HP hosts.
  3. Sends syntactically valid but unsigned JWTs. Validators often move past
     "malformed" to a specific complaint — "invalid issuer", "audience
     mismatch", "signature verification failed" — and that error text tells you
     what it expected.

Nothing here authenticates anything. It is purely for producing evidence to send
to your HP contact.

    cd ~/HPAPI
    sudo -u ubuntu .venv/bin/python tools/probe_catalog_jwt.py
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import sys
import time
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_catalog_auth import load_env, mask  # noqa: E402

DISCOVERY_PATHS = [
    "/.well-known/openid-configuration",
    "/.well-known/oauth-authorization-server",
    "/generic-router/.well-known/openid-configuration",
    "/generic-router/api/.well-known/openid-configuration",
]

DISCOVERY_HOSTS = [
    "https://hpit-gw.hpcloud.hp.com",
]

INTERESTING_HEADERS = {
    "www-authenticate",
    "x-hp-error",
    "x-error",
    "x-error-message",
    "x-request-id",
    "x-correlation-id",
    "x-amzn-errortype",
    "x-apigw-error",
    "server",
    "via",
    "x-powered-by",
    "x-gateway",
    "x-hp-gateway",
    "location",
    "realm",
}


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def make_jwt(header: dict, payload: dict, signature: str = "not-a-real-signature") -> str:
    """Build a well-formed but unsigned JWT.

    The point is to get past 'malformed token' so the validator states what it
    actually wanted. This cannot authenticate — there is no valid signature.
    """
    return ".".join(
        [
            b64url(json.dumps(header, separators=(",", ":")).encode()),
            b64url(json.dumps(payload, separators=(",", ":")).encode()),
            b64url(signature.encode()),
        ]
    )


async def dump_headers(client: httpx.AsyncClient, label: str, url: str, headers: dict, body: dict) -> None:
    print(f"\n--- {label} ---")
    try:
        response = await client.post(url, json=body, headers=headers)
    except httpx.HTTPError as exc:
        print(f"  ERROR {type(exc).__name__}: {exc}")
        return

    print(f"  HTTP {response.status_code}")
    print(f"  body: {response.text.strip()[:300]}")
    shown = False
    for name, value in response.headers.items():
        if name.lower() in INTERESTING_HEADERS:
            print(f"  >> {name}: {value}")
            shown = True
    if not shown:
        print("  (no issuer-revealing headers present)")
        print(f"  all headers: {', '.join(sorted(response.headers.keys()))}")


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file")
    parser.add_argument("--product", default="2Z599F")
    args = parser.parse_args()

    env = load_env(args.env_file)
    base = env.get(
        "HP_CATALOG_BASE_URL", "https://hpit-gw.hpcloud.hp.com/generic-router/api/hermes"
    ).rstrip("/")
    client_id = env.get("HP_CATALOG_CLIENT_ID", "")
    client_secret = env.get("HP_CATALOG_CLIENT_SECRET", "")
    url = f"{base}/images"

    print(f"Target:    {url}")
    print(f"Client ID: {mask(client_id)}")

    body = {
        "requestContext": {
            "requesterId": env.get("HP_CATALOG_REQUESTER_ID", "") or client_id,
            "countryCode": env.get("HP_COUNTRY_CODE", "US"),
            "languageCode": env.get("HP_LANGUAGE_CODE", "en"),
        },
        "productNumbers": [args.product],
        "products": [{"productNumber": args.product}],
    }
    json_headers = {"Accept": "application/json", "Content-Type": "application/json"}

    async with httpx.AsyncClient(timeout=httpx.Timeout(20.0), follow_redirects=False) as client:
        print("\n" + "=" * 72)
        print("STEP 1 — response headers (looking for a named issuer or realm)")
        print("=" * 72)
        await dump_headers(client, "no Authorization header", url, dict(json_headers), body)
        await dump_headers(
            client, "Authorization: Bearer <client_secret>", url,
            {**json_headers, "Authorization": f"Bearer {client_secret}"}, body,
        )

        print("\n" + "=" * 72)
        print("STEP 2 — OIDC discovery documents")
        print("=" * 72)
        for host in DISCOVERY_HOSTS:
            for path in DISCOVERY_PATHS:
                discovery_url = f"{host}{path}"
                try:
                    response = await client.get(discovery_url, headers={"Accept": "application/json"})
                except httpx.HTTPError as exc:
                    print(f"  {discovery_url}\n    ERROR {type(exc).__name__}")
                    continue
                marker = "  <<< FOUND" if response.status_code == 200 else ""
                print(f"  {discovery_url}\n    HTTP {response.status_code}{marker}")
                if response.status_code == 200:
                    print(f"    {response.text.strip()[:600]}")

        print("\n" + "=" * 72)
        print("STEP 3 — well-formed unsigned JWTs (to sharpen the error message)")
        print("=" * 72)
        now = int(time.time())
        variants = [
            (
                "HS256, generic claims",
                make_jwt(
                    {"alg": "HS256", "typ": "JWT"},
                    {"iss": "probe", "sub": client_id, "aud": "hermes",
                     "iat": now, "exp": now + 3600},
                ),
            ),
            (
                "alg=none",
                make_jwt(
                    {"alg": "none", "typ": "JWT"},
                    {"iss": "probe", "sub": client_id, "aud": "hermes",
                     "iat": now, "exp": now + 3600},
                    signature="",
                ),
            ),
            (
                "RS256, client_id as sub and aud",
                make_jwt(
                    {"alg": "RS256", "typ": "JWT", "kid": "probe"},
                    {"iss": "probe", "sub": client_id, "aud": client_id,
                     "client_id": client_id, "iat": now, "exp": now + 3600},
                ),
            ),
            (
                "expired token",
                make_jwt(
                    {"alg": "HS256", "typ": "JWT"},
                    {"iss": "probe", "sub": client_id, "aud": "hermes",
                     "iat": now - 7200, "exp": now - 3600},
                ),
            ),
        ]
        for label, token in variants:
            try:
                response = await client.post(
                    url, json=body,
                    headers={**json_headers, "Authorization": f"Bearer {token}"},
                )
            except httpx.HTTPError as exc:
                print(f"  {label:34} -> ERROR {type(exc).__name__}")
                continue
            text = response.text.strip().replace("\n", " ")[:160]
            print(f"  {label:34} -> {response.status_code} {text}")

        print("\n" + "=" * 72)
        print("HOW TO READ THIS")
        print("=" * 72)
        print(
            "If every unsigned JWT still returns exactly 'Invalid token.', the gateway\n"
            "reveals nothing more and the issuer has to come from HP. Send them this:\n"
            "\n"
            "  - The endpoint you are calling and that it requires a JWT bearer token\n"
            "  - That client id/secret produce 401 'Invalid token.' when sent as Basic\n"
            "    or as a bearer value directly\n"
            "  - That no token endpoint exists on the gateway itself\n"
            "  - Ask: which identity provider issues the JWT, what the token URL,\n"
            "    audience and scope are, and whether these credentials are provisioned\n"
            "    for this gateway at all (they may predate it)\n"
            "\n"
            "If a message names an issuer, audience or JWKS URL, that is your answer:\n"
            "set HP_CATALOG_AUTH_MODE=oauth2 and HP_CATALOG_TOKEN_URL to match."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
