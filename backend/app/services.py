import json
from datetime import date

from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from .models import MarketStatus, PortfolioAlertState, PortfolioHolding, Stock, StockPrice, SyncLog, User
from .ngx_client import (
    NgxFetchError,
    fetch_all_stocks_from_ngx,
    fetch_historical_prices_cached,
    fetch_market_status_from_ngx,
    legacy_seed_stocks,
)
from .settings import get_settings
from .schemas import HoldingUpsert


def upsert_stock(db: Session, stock_data: dict) -> Stock:
    stock = db.get(Stock, stock_data["symbol"])
    if stock is None:
        stock = Stock(symbol=stock_data["symbol"])
        db.add(stock)

    for field, value in stock_data.items():
        if hasattr(stock, field) and value is not None:
            setattr(stock, field, value)
    return stock


STALE_DATA_MESSAGE = "Issue with NGX server. Current data might not be up to date."


def record_sync_log(
    db: Session,
    *,
    status: str,
    source: str,
    stocks_upserted: int = 0,
    history_rows_upserted: int = 0,
    message: str | None = None,
) -> SyncLog:
    log = SyncLog(
        status=status,
        source=source,
        stocks_upserted=stocks_upserted,
        history_rows_upserted=history_rows_upserted,
        message=message,
    )
    db.add(log)
    return log


def sync_stocks(db: Session, include_history: bool = False) -> tuple[str, int, int, str, str | None]:
    settings = get_settings()
    source = "ngxpulse" if settings.ngxpulse_enabled else "ngx_doclib"
    try:
        stocks = fetch_all_stocks_from_ngx()
    except NgxFetchError as exc:
        existing_count = db.scalar(select(func.count()).select_from(Stock)) or 0
        message = f"{STALE_DATA_MESSAGE} {exc}"
        if existing_count:
            record_sync_log(db, status="warning", source=source, message=message)
            db.commit()
            return "database_cache", 0, 0, "warning", message

        stocks = legacy_seed_stocks()
        source = "legacy_stock_mapping"
        if not stocks:
            record_sync_log(db, status="failed", source="ngx_doclib", message=message)
            db.commit()
            return source, 0, 0, "failed", message
    else:
        if not stocks:
            message = "NGX returned no equities. Existing database rows were left unchanged."
            record_sync_log(db, status="warning", source=source, message=message)
            db.commit()
            return "database_cache", 0, 0, "warning", message

    history_count = 0
    for stock_data in stocks:
        stock = upsert_stock(db, stock_data)
        if include_history and (settings.ngxpulse_enabled or stock.ngx_id):
            history_count += upsert_stock_history(db, stock.symbol, stock.ngx_id)
        history_count += upsert_daily_stock_snapshot(db, stock)

    record_sync_log(
        db,
        status="success",
        source=source,
        stocks_upserted=len(stocks),
        history_rows_upserted=history_count,
    )
    db.commit()
    return source, len(stocks), history_count, "success", None


def sync_status(db: Session) -> dict:
    last_attempt = db.scalar(select(SyncLog).order_by(SyncLog.created_at.desc(), SyncLog.id.desc()).limit(1))
    last_success = db.scalar(
        select(SyncLog).where(SyncLog.status == "success").order_by(SyncLog.created_at.desc(), SyncLog.id.desc()).limit(1)
    )
    stocks_count = db.scalar(select(func.count()).select_from(Stock)) or 0
    status = last_attempt.status if last_attempt else "never_synced"
    message = last_attempt.message if last_attempt else "Stock data has not synced yet."
    return {
        "status": status,
        "source": last_attempt.source if last_attempt else None,
        "message": message,
        "last_success_at": last_success.created_at if last_success else None,
        "last_attempt_at": last_attempt.created_at if last_attempt else None,
        "stocks_count": stocks_count,
    }


def sync_logs_query(db: Session, limit: int = 50) -> list[SyncLog]:
    return list(db.scalars(select(SyncLog).order_by(SyncLog.created_at.desc(), SyncLog.id.desc()).limit(limit)).all())


def refresh_market_status(db: Session) -> dict:
    try:
        status_text, payload = fetch_market_status_from_ngx()
    except NgxFetchError as exc:
        cached = db.scalar(select(MarketStatus).order_by(MarketStatus.updated_at.desc(), MarketStatus.id.desc()).limit(1))
        message = f"{STALE_DATA_MESSAGE} {exc}"
        if cached:
            cached.message = message
            db.commit()
            db.refresh(cached)
            return market_status_to_dict(cached, stale=True)
        cached = MarketStatus(status="UNKNOWN", source="ngx_doclib", message=message)
        db.add(cached)
        db.commit()
        db.refresh(cached)
        return market_status_to_dict(cached, stale=True)

    cached = db.scalar(select(MarketStatus).order_by(MarketStatus.updated_at.desc(), MarketStatus.id.desc()).limit(1))
    if cached is None:
        cached = MarketStatus(status=status_text, source="ngx_doclib")
        db.add(cached)
    cached.status = status_text
    cached.source = "ngx_doclib"
    cached.message = None
    cached.raw_payload = json.dumps(payload)
    db.commit()
    db.refresh(cached)
    return market_status_to_dict(cached, stale=False)


def market_status_to_dict(status: MarketStatus, stale: bool = False) -> dict:
    return {
        "status": status.status,
        "source": status.source,
        "message": status.message,
        "updated_at": status.updated_at,
        "stale": stale,
    }


def get_cached_market_status(db: Session) -> dict:
    cached = db.scalar(select(MarketStatus).order_by(MarketStatus.updated_at.desc(), MarketStatus.id.desc()).limit(1))
    if cached is None:
        return refresh_market_status(db)
    return market_status_to_dict(cached, stale=bool(cached.message))


def upsert_stock_history(
    db: Session,
    symbol: str,
    ngx_id: str | None,
    *,
    since: date | None = None,
) -> int:
    source = "ngxpulse_history" if get_settings().ngxpulse_enabled else "ngx_chart"
    try:
        rows = fetch_historical_prices_cached(
            symbol,
            ngx_id,
            from_date=since,
            to_date=date.today(),
        )
    except NgxFetchError as exc:
        record_sync_log(
            db,
            status="warning",
            source=source,
            message=f"{STALE_DATA_MESSAGE} {exc}",
        )
        return 0

    count = 0
    for row in rows:
        base_insert = insert(StockPrice).values(stock_symbol=symbol, **row)
        stmt = base_insert.on_conflict_do_update(
            constraint="uq_stock_prices_symbol_date",
            set_={
                "close_price": base_insert.excluded.close_price,
                "open_price": base_insert.excluded.open_price,
                "high_price": base_insert.excluded.high_price,
                "low_price": base_insert.excluded.low_price,
                "volume": base_insert.excluded.volume,
                "updated_at": func.now(),
            },
        )
        db.execute(stmt)
        count += 1
    return count


def upsert_daily_stock_snapshot(db: Session, stock: Stock) -> int:
    if stock.last_price is None:
        return 0

    snapshot_close = float(stock.last_price)
    snapshot_open = float(stock.open_price or stock.previous_close or stock.last_price)
    snapshot_high = float(stock.high_price) if stock.high_price is not None else snapshot_close
    snapshot_low = float(stock.low_price) if stock.low_price is not None else snapshot_close
    snapshot_volume = float(stock.volume) if stock.volume is not None else None

    base_insert = insert(StockPrice).values(
        stock_symbol=stock.symbol,
        trade_date=date.today(),
        open_price=snapshot_open,
        high_price=snapshot_high,
        low_price=snapshot_low,
        close_price=snapshot_close,
        volume=snapshot_volume,
    )
    stmt = base_insert.on_conflict_do_update(
        constraint="uq_stock_prices_symbol_date",
        set_={
            "open_price": base_insert.excluded.open_price,
            "high_price": base_insert.excluded.high_price,
            "low_price": base_insert.excluded.low_price,
            "close_price": base_insert.excluded.close_price,
            "volume": base_insert.excluded.volume,
            "updated_at": func.now(),
        },
    )
    db.execute(stmt)
    return 1


def holding_to_dict(holding: PortfolioHolding) -> dict:
    current_price = float(holding.stock.last_price) if holding.stock and holding.stock.last_price is not None else None
    quantity = float(holding.quantity)
    avg_price = float(holding.avg_purchase_price)
    total_cost = quantity * avg_price
    total_value = quantity * (current_price or 0)
    profit_loss = total_value - total_cost
    profit_loss_percent = (profit_loss / total_cost * 100) if total_cost else None

    return {
        "stock_symbol": holding.stock_symbol,
        "stock_name": holding.stock.name if holding.stock else holding.stock_symbol,
        "quantity": quantity,
        "avg_purchase_price": avg_price,
        "current_price": current_price,
        "total_value": total_value,
        "total_cost": total_cost,
        "profit_loss": profit_loss,
        "profit_loss_percent": profit_loss_percent,
        "notes": holding.notes,
    }


def upsert_holding(db: Session, user: User, payload: HoldingUpsert) -> PortfolioHolding:
    symbol = payload.stock_symbol.strip().upper()
    stock = db.get(Stock, symbol)
    if stock is None:
        stock = Stock(symbol=symbol, name=payload.manual_name or symbol, source="manual")
        db.add(stock)

    if payload.manual_name:
        stock.name = payload.manual_name
    if payload.manual_current_price is not None:
        stock.last_price = payload.manual_current_price
        stock.source = "manual"

    holding = db.scalar(
        select(PortfolioHolding).where(PortfolioHolding.user_id == user.id, PortfolioHolding.stock_symbol == symbol)
    )
    if holding is None:
        holding = PortfolioHolding(user_id=user.id, stock_symbol=symbol)
        db.add(holding)

    holding.quantity = payload.quantity
    holding.avg_purchase_price = payload.avg_purchase_price
    holding.notes = payload.notes
    db.commit()
    db.refresh(holding)
    return holding


def delete_holding(db: Session, user: User, symbol: str) -> bool:
    normalized_symbol = symbol.strip().upper()
    db.execute(
        delete(PortfolioAlertState).where(
            PortfolioAlertState.user_id == user.id,
            PortfolioAlertState.stock_symbol == normalized_symbol,
        )
    )
    result = db.execute(
        delete(PortfolioHolding).where(
            PortfolioHolding.user_id == user.id,
            PortfolioHolding.stock_symbol == normalized_symbol,
        )
    )
    db.commit()
    return bool(result.rowcount)


def stock_history_query(db: Session, symbol: str, since: date):
    return (
        db.scalars(
            select(StockPrice)
            .where(StockPrice.stock_symbol == symbol.strip().upper(), StockPrice.trade_date >= since)
            .order_by(StockPrice.trade_date)
        )
        .unique()
        .all()
    )
