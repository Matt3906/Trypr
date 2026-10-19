from functools import lru_cache
from urllib.parse import quote

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "Trypr API"
    environment: str = "development"
    log_level: str = "INFO"

    # --- Postgres ---------------------------------------------------------
    database_url: str | None = None
    db_user: str = "postgres"
    db_password: str = "postgres"
    db_name: str = "trypr"
    db_host: str = "127.0.0.1"
    db_port: int = 5432

    # --- Web / CORS -------------------------------------------------------
    # The site is static files on Hostinger (tryprtravel.com); this API lives on
    # api.tryprtravel.com. Both share the registrable domain, so the SameSite=Lax
    # session cookie is sent with credentialed fetches from the site.
    cors_origins: str = (
        "https://tryprtravel.com,https://www.tryprtravel.com,"
        "http://localhost:5173,http://127.0.0.1:5173"
    )
    frontend_base_url: str = "https://tryprtravel.com"

    # --- Auth -------------------------------------------------------------
    session_cookie_name: str = "trypr_session"
    session_ttl_days: int = 30
    admin_emails: str = "matthewgockiewicz@gmail.com"

    # --- Files ------------------------------------------------------------
    upload_dir: str = "/data/uploads"
    max_upload_mb: int = 25

    # --- Email (password resets) -----------------------------------------
    # DigitalOcean blocks outbound SMTP, so production uses the Gmail API (HTTPS).
    email_provider: str = "log"  # log | gmail_api
    sender_address: str = "no-reply@tryprtravel.com"
    sender_name: str = "Trypr"
    gmail_client_id: str | None = None
    gmail_client_secret: str | None = None
    gmail_refresh_token: str | None = None

    # --- Stripe -----------------------------------------------------------
    stripe_secret_key: str = ""
    stripe_webhook_secret: str = ""
    stripe_price_monthly: str = ""
    stripe_price_yearly: str = ""
    stripe_allowed_origins: str = ""
    stripe_success_path: str = "/premium"
    stripe_cancel_path: str = "/premium"
    stripe_portal_return_path: str = "/premium"

    # --- AI suggestions ---------------------------------------------------
    anthropic_api_key: str = ""
    ai_model: str = "claude-opus-5-5"

    # --- Routing proxies --------------------------------------------------
    openrouteservice_api_key: str = ""
    graphhopper_api_key: str = ""

    @property
    def is_production(self) -> bool:
        return self.environment.lower() == "production"

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip().rstrip("/") for o in self.cors_origins.split(",") if o.strip()]

    @property
    def admin_email_set(self) -> set[str]:
        return {e.strip().lower() for e in self.admin_emails.split(",") if e.strip()}

    @property
    def dsn(self) -> str:
        if self.database_url:
            return self.database_url.replace("postgresql+asyncpg://", "postgresql://", 1)
        return (
            f"postgresql://{quote(self.db_user, safe='')}:{quote(self.db_password, safe='')}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
