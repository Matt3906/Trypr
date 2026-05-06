from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "Trypr API"
    environment: str = "development"

    database_url: str | None = Field(default=None, alias="DATABASE_URL")
    db_user: str = Field(default="postgres", alias="DB_USER")
    db_password: str = Field(default="postgres", alias="DB_PASSWORD")
    db_name: str = Field(default="postgres", alias="DB_NAME")
    db_host: str = Field(default="127.0.0.1", alias="DB_HOST")
    db_port: int = Field(default=5432, alias="DB_PORT")

    # Cloud SQL Auth Proxy convention is localhost:5432.
    use_cloud_sql_proxy: bool = Field(default=False, alias="USE_CLOUD_SQL_PROXY")
    cloud_sql_instance: str | None = Field(default=None, alias="CLOUD_SQL_INSTANCE")

    firebase_project_id: str = Field(default="trypr-5ee47", alias="FIREBASE_PROJECT_ID")
    firebase_credentials_path: str | None = Field(
        default=None,
        alias="GOOGLE_APPLICATION_CREDENTIALS",
    )

    cors_origins: str = Field(
        default="https://refportal.trypr.com,http://localhost:5173,http://127.0.0.1:5173",
        alias="CORS_ORIGINS",
    )
    frontend_base_url: str = Field(default="https://refportal.trypr.com", alias="FRONTEND_BASE_URL")
    ref_portal_action_secret: str = Field(default="", alias="REF_PORTAL_ACTION_SECRET")
    admin_emails: str = Field(default="matthewgockiewicz@gmail.com", alias="ADMIN_EMAILS")

    smtp_host: str | None = Field(default=None, alias="SMTP_HOST")
    smtp_port: int = Field(default=25, alias="SMTP_PORT")
    smtp_username: str | None = Field(default=None, alias="SMTP_USERNAME")
    smtp_api_key: str | None = Field(default=None, alias="SMTP_API_KEY")
    smtp_password: str | None = Field(default=None, alias="SMTP_PASSWORD")
    smtp_sender: str = Field(default="no-reply@refportal.trypr.com", alias="SMTP_SENDER")
    smtp_use_starttls: bool = Field(default=False, alias="SMTP_USE_STARTTLS")

    @property
    def async_database_url(self) -> str:
        if self.database_url:
            if self.database_url.startswith("postgresql+asyncpg://"):
                return self.database_url
            if self.database_url.startswith("postgresql://"):
                return self.database_url.replace("postgresql://", "postgresql+asyncpg://", 1)
            return self.database_url

        host = "127.0.0.1" if self.use_cloud_sql_proxy else self.db_host
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_password}@"
            f"{host}:{self.db_port}/{self.db_name}"
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
