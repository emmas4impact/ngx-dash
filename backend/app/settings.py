from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "NGX Portfolio API"
    database_url: str
    jwt_secret_key: str
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24 * 7
    cors_origins: str = "http://localhost:3000,http://localhost:5173,http://localhost:8080"
    admin_emails: str = ""

    ngx_ticker_url: str = "https://doclib.ngxgroup.com/REST/api/statistics/ticker"
    ngx_chart_base_url: str = "https://doclib.ngxgroup.com/REST/api/stockchartdata/"
    market_status_url: str = "https://doclib.ngxgroup.com/REST/api/statistics/mktstatus"
    enable_background_stock_sync: bool = True
    stock_sync_interval_seconds: int = 10

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def admin_email_list(self) -> list[str]:
        return [email.strip().lower() for email in self.admin_emails.split(",") if email.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
