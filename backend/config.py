import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


@dataclass(frozen=True)
class Settings:
    hp_catalog_base_url: str = os.getenv(
        "HP_CATALOG_BASE_URL",
        "https://hermesws.ext.hp.com/HermesWS/secure/v2",
    )
    hp_catalog_requester_id: str = os.getenv("HP_CATALOG_REQUESTER_ID", "")
    hp_catalog_client_cert: str = os.getenv("HP_CATALOG_CLIENT_CERT", "")
    hp_catalog_client_key: str = os.getenv("HP_CATALOG_CLIENT_KEY", "")
    hp_catalog_client_id: str = os.getenv("HP_CATALOG_CLIENT_ID", "")
    hp_catalog_client_secret: str = os.getenv("HP_CATALOG_CLIENT_SECRET", "")
    hp_country_code: str = os.getenv("HP_COUNTRY_CODE", "US")
    hp_language_code: str = os.getenv("HP_LANGUAGE_CODE", "en")
    hp_shop_base_url: str = os.getenv("HP_SHOP_BASE_URL", "https://www.hp.com/us-en/shop")
    partsurfer_bff_url: str = os.getenv(
        "PARTSURFER_BFF_URL",
        "https://partsurfer.hpcloud.hp.com/bff",
    )
    request_timeout_seconds: float = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "45"))

    @property
    def catalog_requester_id(self) -> str:
        return self.hp_catalog_requester_id or self.hp_catalog_client_id

    @property
    def catalog_configured(self) -> bool:
        has_credentials = bool(self.hp_catalog_client_id and self.hp_catalog_client_secret)
        has_cert = bool(self.hp_catalog_client_cert)
        return has_credentials or (bool(self.hp_catalog_requester_id) and has_cert)


settings = Settings()
