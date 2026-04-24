from datetime import date, datetime

from sqlalchemy import Boolean, Date, DateTime, ForeignKey, Integer, Numeric, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .database import Base


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class User(TimestampMixin, Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    full_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    profile_image_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    phone: Mapped[str | None] = mapped_column(String(64), nullable=True)
    address: Mapped[str | None] = mapped_column(String(255), nullable=True)
    city: Mapped[str | None] = mapped_column(String(128), nullable=True)
    country: Mapped[str | None] = mapped_column(String(128), nullable=True)
    email_verified: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    email_verification_token: Mapped[str | None] = mapped_column(String(128), nullable=True, index=True)
    email_verification_sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    password_reset_token: Mapped[str | None] = mapped_column(String(128), nullable=True, index=True)
    password_reset_sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    is_superuser: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")

    holdings: Mapped[list["PortfolioHolding"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    push_tokens: Mapped[list["PushDeviceToken"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class Stock(TimestampMixin, Base):
    __tablename__ = "stocks"

    symbol: Mapped[str] = mapped_column(String(32), primary_key=True)
    name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    ticker_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    ngx_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    sector: Mapped[str | None] = mapped_column(String(128), nullable=True)
    last_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    previous_close: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    open_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    high_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    low_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    volume: Mapped[float | None] = mapped_column(Numeric(20, 2), nullable=True)
    market_cap: Mapped[float | None] = mapped_column(Numeric(24, 2), nullable=True)
    change: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    percent_change: Mapped[float | None] = mapped_column(Numeric(10, 4), nullable=True)
    margin: Mapped[float | None] = mapped_column(Numeric(10, 4), nullable=True)
    source: Mapped[str | None] = mapped_column(String(64), nullable=True)

    prices: Mapped[list["StockPrice"]] = relationship(back_populates="stock", cascade="all, delete-orphan")
    holdings: Mapped[list["PortfolioHolding"]] = relationship(back_populates="stock")


class StockPrice(TimestampMixin, Base):
    __tablename__ = "stock_prices"
    __table_args__ = (UniqueConstraint("stock_symbol", "trade_date", name="uq_stock_prices_symbol_date"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    stock_symbol: Mapped[str] = mapped_column(ForeignKey("stocks.symbol", ondelete="CASCADE"), index=True)
    trade_date: Mapped[date] = mapped_column(Date, index=True)
    open_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    high_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    low_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    close_price: Mapped[float] = mapped_column(Numeric(18, 4))
    volume: Mapped[float | None] = mapped_column(Numeric(20, 2), nullable=True)

    stock: Mapped[Stock] = relationship(back_populates="prices")


class SyncLog(TimestampMixin, Base):
    __tablename__ = "sync_logs"

    id: Mapped[int] = mapped_column(primary_key=True)
    status: Mapped[str] = mapped_column(String(32), index=True)
    source: Mapped[str] = mapped_column(String(64), index=True)
    stocks_upserted: Mapped[int] = mapped_column(Integer, default=0)
    history_rows_upserted: Mapped[int] = mapped_column(Integer, default=0)
    message: Mapped[str | None] = mapped_column(Text, nullable=True)


class MarketStatus(TimestampMixin, Base):
    __tablename__ = "market_status"

    id: Mapped[int] = mapped_column(primary_key=True)
    status: Mapped[str] = mapped_column(String(128), index=True)
    source: Mapped[str] = mapped_column(String(64), default="ngx_doclib")
    message: Mapped[str | None] = mapped_column(Text, nullable=True)
    raw_payload: Mapped[str | None] = mapped_column(Text, nullable=True)


class PortfolioHolding(TimestampMixin, Base):
    __tablename__ = "portfolio_holdings"
    __table_args__ = (UniqueConstraint("user_id", "stock_symbol", name="uq_portfolio_user_stock"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    stock_symbol: Mapped[str] = mapped_column(ForeignKey("stocks.symbol", ondelete="RESTRICT"), index=True)
    quantity: Mapped[float] = mapped_column(Numeric(20, 4))
    avg_purchase_price: Mapped[float] = mapped_column(Numeric(18, 4))
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    user: Mapped[User] = relationship(back_populates="holdings")
    stock: Mapped[Stock] = relationship(back_populates="holdings")


class PushDeviceToken(TimestampMixin, Base):
    __tablename__ = "push_device_tokens"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token: Mapped[str] = mapped_column(String(512), unique=True, index=True)
    platform: Mapped[str] = mapped_column(String(32), index=True)
    device_label: Mapped[str | None] = mapped_column(String(255), nullable=True)
    notifications_enabled: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    last_registered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    user: Mapped[User] = relationship(back_populates="push_tokens")


class PortfolioAlertState(TimestampMixin, Base):
    __tablename__ = "portfolio_alert_states"
    __table_args__ = (UniqueConstraint("user_id", "stock_symbol", name="uq_portfolio_alert_user_stock"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    stock_symbol: Mapped[str] = mapped_column(ForeignKey("stocks.symbol", ondelete="CASCADE"), index=True)
    baseline_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    last_seen_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    last_alert_price: Mapped[float | None] = mapped_column(Numeric(18, 4), nullable=True)
    last_alert_change_percent: Mapped[float | None] = mapped_column(Numeric(10, 4), nullable=True)
    last_notified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class AccountDeletionRequest(TimestampMixin, Base):
    __tablename__ = "account_deletion_requests"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), index=True)
    reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    source: Mapped[str] = mapped_column(String(32), default="web")
    status: Mapped[str] = mapped_column(String(32), default="pending", index=True)
