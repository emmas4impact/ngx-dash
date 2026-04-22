from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "NGX Portfolio API"
    database_url: str = Field(validation_alias="DATABASE_URL")
    jwt_secret_key: str = Field(validation_alias="JWT_SECRET_KEY")
    jwt_algorithm: str = Field(default="HS256", validation_alias="JWT_ALGORITHM")
    access_token_expire_minutes: int = Field(default=60 * 24 * 7, validation_alias="ACCESS_TOKEN_EXPIRE_MINUTES")
    cors_origins: str = Field(
        default="http://localhost:3000,http://localhost:5173,http://localhost:8080",
        validation_alias="CORS_ORIGINS",
    )
    admin_emails: str = Field(default="", validation_alias="ADMIN_EMAILS")

    ngx_ticker_url: str = Field(
        default="https://doclib.ngxgroup.com/REST/api/statistics/ticker",
        validation_alias="NGX_TICKER_URL",
    )
    ngx_chart_base_url: str = Field(
        default="https://doclib.ngxgroup.com/REST/api/stockchartdata/",
        validation_alias="NGX_CHART_BASE_URL",
    )
    market_status_url: str = Field(
        default="https://doclib.ngxgroup.com/REST/api/statistics/mktstatus",
        validation_alias="MARKET_STATUS_URL",
    )
    enable_background_stock_sync: bool = Field(default=True, validation_alias="ENABLE_BACKGROUND_STOCK_SYNC")
    stock_sync_interval_seconds: int = Field(default=10, validation_alias="STOCK_SYNC_INTERVAL_SECONDS")

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    @field_validator("database_url")
    @classmethod
    def normalize_database_url(cls, value: str) -> str:
        if value.startswith("postgresql://"):
            return f"postgresql+psycopg://{value.removeprefix('postgresql://')}"
        if value.startswith("postgres://"):
            return f"postgresql+psycopg://{value.removeprefix('postgres://')}"
        return value

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def admin_email_list(self) -> list[str]:
        return [email.strip().lower() for email in self.admin_emails.split(",") if email.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
