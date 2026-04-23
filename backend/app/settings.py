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
    market_snapshot_url: str = Field(
        default="https://doclib.ngxgroup.com/REST/api/mrkstat/mrksnapshot",
        validation_alias="MARKET_SNAPSHOT_URL",
    )
    company_news_url: str = Field(
        default="https://doclib.ngxgroup.com/_api/Web/Lists/GetByTitle('XFinancial_News')/items/",
        validation_alias="COMPANY_NEWS_URL",
    )
    company_profile_url: str = Field(
        default="https://ngxgroup.com/exchange/data/company-profile/",
        validation_alias="COMPANY_PROFILE_URL",
    )
    enable_background_stock_sync: bool = Field(default=True, validation_alias="ENABLE_BACKGROUND_STOCK_SYNC")
    stock_sync_interval_seconds: int = Field(default=15 * 60, validation_alias="STOCK_SYNC_INTERVAL_SECONDS")
    frontend_base_url: str = Field(default="http://localhost:8080", validation_alias="FRONTEND_BASE_URL")
    smtp_host: str | None = Field(default=None, validation_alias="SMTP_HOST")
    smtp_port: int = Field(default=587, validation_alias="SMTP_PORT")
    smtp_username: str | None = Field(default=None, validation_alias="SMTP_USERNAME")
    smtp_password: str | None = Field(default=None, validation_alias="SMTP_PASSWORD")
    smtp_from_email: str | None = Field(default=None, validation_alias="SMTP_FROM_EMAIL")
    smtp_use_tls: bool = Field(default=True, validation_alias="SMTP_USE_TLS")
    resend_api_key: str | None = Field(default=None, validation_alias="RESEND_API_KEY")
    resend_from_email: str | None = Field(default=None, validation_alias="RESEND_FROM_EMAIL")

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

    @property
    def email_enabled(self) -> bool:
        return bool(
            (self.resend_api_key and (self.resend_from_email or self.smtp_from_email))
            or (self.smtp_host and (self.smtp_from_email or self.smtp_username))
        )

    @property
    def from_email(self) -> str | None:
        return self.resend_from_email or self.smtp_from_email or self.smtp_username

    @property
    def email_provider(self) -> str:
        if self.resend_api_key:
            return "resend"
        if self.smtp_host:
            return "smtp"
        return "none"


@lru_cache
def get_settings() -> Settings:
    return Settings()
