import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"false", "0", "no", "off", ""}


@dataclass(frozen=True)
class Settings:
    hp_catalog_base_url: str = os.getenv(
        "HP_CATALOG_BASE_URL",
        "https://hpit-gw.hpcloud.hp.com/generic-router/api/hermes",
    )
    hp_catalog_requester_id: str = os.getenv("HP_CATALOG_REQUESTER_ID", "")
    hp_catalog_client_cert: str = os.getenv("HP_CATALOG_CLIENT_CERT", "")
    hp_catalog_client_key: str = os.getenv("HP_CATALOG_CLIENT_KEY", "")
    hp_catalog_client_id: str = os.getenv("HP_CATALOG_CLIENT_ID", "")
    hp_catalog_client_secret: str = os.getenv("HP_CATALOG_CLIENT_SECRET", "")

    # How to authenticate to the catalog gateway. The old hermesws endpoint took
    # HTTP Basic; the hpit-gw gateway answers Basic with 401 "Invalid token", so
    # it wants something else. Run tools/probe_catalog_auth.py to find out which,
    # then set this. One of: basic | bearer | apikey | oauth2
    hp_catalog_auth_mode: str = os.getenv("HP_CATALOG_AUTH_MODE", "basic").strip().lower()
    # Header name used when auth mode is "apikey".
    hp_catalog_api_key_header: str = os.getenv("HP_CATALOG_API_KEY_HEADER", "x-api-key")
    # Which credential carries the key/token for apikey and bearer modes.
    hp_catalog_api_key_value: str = os.getenv("HP_CATALOG_API_KEY_VALUE", "")
    # Token endpoint for oauth2 client_credentials mode.
    hp_catalog_token_url: str = os.getenv("HP_CATALOG_TOKEN_URL", "")
    hp_catalog_oauth_scope: str = os.getenv("HP_CATALOG_OAUTH_SCOPE", "")
    hp_country_code: str = os.getenv("HP_COUNTRY_CODE", "US")
    hp_language_code: str = os.getenv("HP_LANGUAGE_CODE", "en")
    hp_shop_base_url: str = os.getenv("HP_SHOP_BASE_URL", "https://www.hp.com/us-en/shop")
    partsurfer_bff_url: str = os.getenv(
        "PARTSURFER_BFF_URL",
        "https://partsurfer.hpcloud.hp.com/bff",
    )

    # Timeout for a SINGLE upstream HTTP call. Deliberately short: one product
    # makes up to five upstream calls, so a large value multiplies into minutes
    # of wall clock and the connection gets dropped by the browser or an
    # intermediate proxy long before the response is ready.
    request_timeout_seconds: float = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "15"))

    # Hard ceiling on all work for one product across every upstream it tries.
    # Exceeding it produces a "timed out" result for that product instead of
    # stalling the whole batch.
    product_timeout_seconds: float = float(os.getenv("PRODUCT_TIMEOUT_SECONDS", "40"))

    # How many products are looked up simultaneously. Higher finishes sooner but
    # raises the chance HP rate-limits or blocks the source IP.
    max_concurrency: int = int(os.getenv("MAX_CONCURRENCY", "5"))

    # Set HP_SHOP_ENABLED=false to skip the HP Shop scrape entirely. Worth doing
    # when HP blocks the host's IP range: there the scrape can only ever time
    # out, so skipping it removes a guaranteed delay from every lookup.
    hp_shop_enabled: bool = _env_bool("HP_SHOP_ENABLED", True)

    @property
    def catalog_requester_id(self) -> str:
        return self.hp_catalog_requester_id or self.hp_catalog_client_id

    @property
    def catalog_configured(self) -> bool:
        has_credentials = bool(self.hp_catalog_client_id and self.hp_catalog_client_secret)
        has_cert = bool(self.hp_catalog_client_cert)
        return has_credentials or (bool(self.hp_catalog_requester_id) and has_cert)


settings = Settings()
