from datetime import date, datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=72)
    full_name: str | None = None


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=72)


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserOut(BaseModel):
    id: int
    email: EmailStr
    full_name: str | None = None
    phone: str | None = None
    address: str | None = None
    city: str | None = None
    country: str | None = None
    email_verified: bool = False
    is_superuser: bool = False
    created_at: datetime | None = None
    updated_at: datetime | None = None

    model_config = ConfigDict(from_attributes=True)


class ProfileUpdate(BaseModel):
    full_name: str | None = Field(default=None, max_length=255)
    phone: str | None = Field(default=None, max_length=64)
    address: str | None = Field(default=None, max_length=255)
    city: str | None = Field(default=None, max_length=128)
    country: str | None = Field(default=None, max_length=128)


class PasswordChangeRequest(BaseModel):
    current_password: str = Field(min_length=1, max_length=72)
    new_password: str = Field(min_length=8, max_length=72)


class AccountDeleteRequest(BaseModel):
    password: str = Field(min_length=1, max_length=72)


class PushTokenUpsert(BaseModel):
    token: str = Field(min_length=16, max_length=512)
    platform: str = Field(min_length=2, max_length=32)
    device_label: str | None = Field(default=None, max_length=255)


class PushTokenDelete(BaseModel):
    token: str = Field(min_length=16, max_length=512)


class MessageResponse(BaseModel):
    message: str
    verification_url: str | None = None


class StockOut(BaseModel):
    symbol: str
    name: str | None = None
    ticker_id: str | None = None
    ngx_id: str | None = None
    sector: str | None = None
    last_price: float | None = None
    previous_close: float | None = None
    open_price: float | None = None
    high_price: float | None = None
    low_price: float | None = None
    volume: float | None = None
    market_cap: float | None = None
    change: float | None = None
    percent_change: float | None = None
    margin: float | None = None
    source: str | None = None
    updated_at: datetime | None = None

    model_config = ConfigDict(from_attributes=True)


class StockPriceOut(BaseModel):
    trade_date: date
    close_price: float
    open_price: float | None = None
    high_price: float | None = None
    low_price: float | None = None
    volume: float | None = None

    model_config = ConfigDict(from_attributes=True)


class HoldingUpsert(BaseModel):
    stock_symbol: str = Field(min_length=1, max_length=32)
    quantity: float = Field(gt=0)
    avg_purchase_price: float = Field(ge=0)
    manual_name: str | None = None
    manual_current_price: float | None = Field(default=None, ge=0)
    notes: str | None = None


class HoldingOut(BaseModel):
    stock_symbol: str
    stock_name: str | None = None
    quantity: float
    avg_purchase_price: float
    current_price: float | None = None
    total_value: float
    total_cost: float
    profit_loss: float
    profit_loss_percent: float | None = None
    notes: str | None = None


class SyncResult(BaseModel):
    source: str
    stocks_upserted: int
    history_rows_upserted: int = 0
    status: str = "success"
    message: str | None = None


class SyncLogOut(BaseModel):
    id: int
    status: str
    source: str
    stocks_upserted: int
    history_rows_upserted: int
    message: str | None = None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class SyncStatusOut(BaseModel):
    status: str
    source: str | None = None
    message: str | None = None
    last_success_at: datetime | None = None
    last_attempt_at: datetime | None = None
    stocks_count: int = 0


class MarketStatusOut(BaseModel):
    status: str
    source: str = "ngx_doclib"
    message: str | None = None
    updated_at: datetime | None = None
    stale: bool = False


class MarketSnapshotOut(BaseModel):
    asi: float | None = None
    deals: float | None = None
    volume: float | None = None
    value: float | None = None
    market_cap: float | None = None
    bond_cap: float | None = None
    etf_cap: float | None = None
    source: str = "ngx_market_snapshot"


class CompanyNewsOut(BaseModel):
    title: str | None = None
    url: str | None = None
    modified: datetime | None = None
    ngx_id: str | None = None
    submission_type: str | None = None


class StockDetailOut(BaseModel):
    stock: StockOut
    history: list[StockPriceOut]
    market_snapshot: MarketSnapshotOut | None = None
    news: list[CompanyNewsOut] = []


class MarketLeadersOut(BaseModel):
    top_movers: list[StockOut]
    top_losers: list[StockOut]


class PushStatusOut(BaseModel):
    enabled: bool
    project_id: str | None = None
    registered_devices: int = 0
    users_with_devices: int = 0
    threshold_percent: float = 5.0


class PushTestRequest(BaseModel):
    title: str | None = Field(default=None, max_length=120)
    body: str | None = Field(default=None, max_length=240)
    symbol: str | None = Field(default=None, max_length=32)


class AccountDeletionRequestCreate(BaseModel):
    email: EmailStr
    reason: str | None = Field(default=None, max_length=2000)


class AccountDeletionRequestOut(BaseModel):
    id: int
    email: EmailStr
    reason: str | None = None
    source: str
    status: str
    created_at: datetime | None = None

    model_config = ConfigDict(from_attributes=True)
