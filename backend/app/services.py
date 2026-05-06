import json
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from .models import ApiCache, MarketStatus, PortfolioAlertState, PortfolioHolding, Stock, StockPrice, SyncLog, User
from .ngx_client import (
    NgxFetchError,
    fetch_all_stocks_from_ngx,
    fetch_company_news_cached,
    fetch_disclosures_cached,
    fetch_dividend_history_cached,
    fetch_historical_prices_cached,
    fetch_market_status_from_ngx,
    fetch_market_news_cached,
    fetch_market_snapshot_cached,
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
REFERENCE_CACHE_SYNC_SOURCE = "reference_cache_sync"
REFERENCE_CACHE_REFRESH_INTERVAL = timedelta(hours=24)
MARKET_SNAPSHOT_CACHE_KEY = "market_snapshot"


def market_news_cache_key(limit: int = 6) -> str:
    return f"market_news:{limit}"


def company_news_cache_key(symbol: str, limit: int = 6) -> str:
    return f"company_news:{symbol.strip().upper()}:{limit}"


def dividend_cache_key(symbol: str, limit: int = 10) -> str:
    return f"dividends:{symbol.strip().upper()}:{limit}"


def disclosure_cache_key(symbol: str, limit: int = 8) -> str:
    return f"disclosures:{symbol.strip().upper()}:{limit}"


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
        if stocks:
            source = str(stocks[0].get("source") or source)
        if not stocks:
            message = "NGX returned no equities. Existing database rows were left unchanged."
            record_sync_log(db, status="warning", source=source, message=message)
            db.commit()
            return "database_cache", 0, 0, "warning", message

    history_count = 0
    for stock_data in stocks:
        stock = upsert_stock(db, stock_data)
        if include_history and (settings.ngxpulse_enabled or stock.ngx_id):
            history_count += upsert_stock_history(
                db,
                stock.symbol,
                stock.ngx_id,
                allow_legacy_fallback=not settings.ngxpulse_enabled,
            )
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


def cache_api_payload(
    db: Session,
    *,
    cache_key: str,
    payload: dict | list,
    source: str | None = None,
) -> ApiCache:
    entry = db.get(ApiCache, cache_key)
    if entry is None:
        entry = ApiCache(cache_key=cache_key, payload="null")
        db.add(entry)
    entry.source = source
    entry.payload = json.dumps(payload, default=str)
    return entry


def get_cached_payload(db: Session, cache_key: str) -> dict | list | None:
    entry = db.get(ApiCache, cache_key)
    if entry is None:
        return None
    try:
        payload = json.loads(entry.payload)
    except (TypeError, ValueError):
        return None
    if isinstance(payload, (dict, list)):
        return payload
    return None


def get_cached_list_payload(db: Session, cache_key: str) -> list[dict]:
    payload = get_cached_payload(db, cache_key)
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    return []


def get_cached_dict_payload(db: Session, cache_key: str) -> dict | None:
    payload = get_cached_payload(db, cache_key)
    if isinstance(payload, dict):
        return payload
    return None


def refresh_market_status(db: Session) -> dict:
    try:
        status_text, payload, source = fetch_market_status_from_ngx()
    except NgxFetchError as exc:
        cached = db.scalar(select(MarketStatus).order_by(MarketStatus.updated_at.desc(), MarketStatus.id.desc()).limit(1))
        message = f"{STALE_DATA_MESSAGE} {exc}"
        if cached:
            cached.message = message
            db.commit()
            db.refresh(cached)
            return market_status_to_dict(cached, stale=True)
        cached = MarketStatus(status="UNKNOWN", source="market_status_cache", message=message)
        db.add(cached)
        db.commit()
        db.refresh(cached)
        return market_status_to_dict(cached, stale=True)

    cached = db.scalar(select(MarketStatus).order_by(MarketStatus.updated_at.desc(), MarketStatus.id.desc()).limit(1))
    if cached is None:
        cached = MarketStatus(status=status_text, source=source)
        db.add(cached)
    cached.status = status_text
    cached.source = source
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


def get_cached_market_snapshot(db: Session, *, refresh_if_missing: bool = True) -> dict | None:
    cached = get_cached_dict_payload(db, MARKET_SNAPSHOT_CACHE_KEY)
    if cached is not None or not refresh_if_missing:
        return cached
    try:
        snapshot = fetch_market_snapshot_cached()
    except NgxFetchError:
        return None
    cache_api_payload(db, cache_key=MARKET_SNAPSHOT_CACHE_KEY, payload=snapshot, source="ngxpulse_market_snapshot")
    db.commit()
    return snapshot


def get_cached_market_news(db: Session, limit: int = 6, *, refresh_if_missing: bool = True) -> list[dict]:
    cache_key = market_news_cache_key(limit)
    cached = get_cached_list_payload(db, cache_key)
    if cached or not refresh_if_missing:
        return cached
    try:
        stories = fetch_market_news_cached(limit)
    except NgxFetchError:
        return []
    cache_api_payload(db, cache_key=cache_key, payload=stories, source="ngxpulse_market_news")
    db.commit()
    return stories


def get_cached_company_news(
    db: Session,
    symbol: str,
    ngx_id: str | None,
    limit: int = 6,
    *,
    refresh_if_missing: bool = True,
) -> list[dict]:
    cache_key = company_news_cache_key(symbol, limit)
    cached = get_cached_list_payload(db, cache_key)
    if cached or not refresh_if_missing or not ngx_id:
        return cached
    try:
        stories = fetch_company_news_cached(ngx_id)[:limit]
    except NgxFetchError:
        return []
    cache_api_payload(db, cache_key=cache_key, payload=stories, source="ngx_company_news")
    db.commit()
    return stories


def get_cached_dividend_history(
    db: Session,
    symbol: str,
    limit: int = 10,
    *,
    refresh_if_missing: bool = True,
) -> list[dict]:
    cache_key = dividend_cache_key(symbol, limit)
    cached = get_cached_list_payload(db, cache_key)
    if cached or not refresh_if_missing:
        return cached
    try:
        history = fetch_dividend_history_cached(symbol, limit)
    except NgxFetchError:
        return []
    cache_api_payload(db, cache_key=cache_key, payload=history, source="ngxpulse_dividends")
    db.commit()
    return history


def get_cached_disclosures(
    db: Session,
    symbol: str,
    limit: int = 8,
    *,
    refresh_if_missing: bool = True,
) -> list[dict]:
    cache_key = disclosure_cache_key(symbol, limit)
    cached = get_cached_list_payload(db, cache_key)
    if cached or not refresh_if_missing:
        return cached
    try:
        disclosures = fetch_disclosures_cached(symbol, limit)
    except NgxFetchError:
        return []
    cache_api_payload(db, cache_key=cache_key, payload=disclosures, source="ngxpulse_disclosures")
    db.commit()
    return disclosures


def upsert_stock_history(
    db: Session,
    symbol: str,
    ngx_id: str | None,
    *,
    since: date | None = None,
    allow_legacy_fallback: bool = True,
) -> int:
    source = "ngxpulse_history" if get_settings().ngxpulse_enabled else "ngx_chart"
    try:
        rows = fetch_historical_prices_cached(
            symbol,
            ngx_id,
            from_date=since,
            to_date=date.today(),
            allow_legacy_fallback=allow_legacy_fallback,
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
    elif payload.merge_with_existing:
        existing_quantity = float(holding.quantity)
        existing_avg_price = float(holding.avg_purchase_price)
        total_quantity = existing_quantity + payload.quantity
        total_cost = (existing_quantity * existing_avg_price) + (
            payload.quantity * payload.avg_purchase_price
        )
        holding.quantity = total_quantity
        holding.avg_purchase_price = total_cost / total_quantity if total_quantity > 0 else payload.avg_purchase_price
    else:
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


def stock_history_query(
    db: Session,
    symbol: str,
    since: date | None = None,
    limit_trading_days: int | None = None,
):
    stmt = select(StockPrice).where(StockPrice.stock_symbol == symbol.strip().upper())
    if since is not None:
        stmt = stmt.where(StockPrice.trade_date >= since)
    rows = list(db.scalars(stmt.order_by(StockPrice.trade_date)).unique().all())
    if limit_trading_days is not None and limit_trading_days > 0:
        rows = rows[-limit_trading_days:]
    return rows


def reference_cache_refresh_due(db: Session) -> bool:
    last_success = db.scalar(
        select(SyncLog)
        .where(SyncLog.source == REFERENCE_CACHE_SYNC_SOURCE, SyncLog.status == "success")
        .order_by(SyncLog.created_at.desc(), SyncLog.id.desc())
        .limit(1)
    )
    if last_success is None:
        return True
    last_created = last_success.created_at
    if last_created.tzinfo is None:
        last_created = last_created.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) - last_created >= REFERENCE_CACHE_REFRESH_INTERVAL


def refresh_reference_caches(db: Session) -> tuple[int, int]:
    stocks = list(db.scalars(select(Stock).order_by(Stock.symbol)).all())
    history_rows = 0
    cache_entries = 0

    if get_settings().ngxpulse_enabled:
        try:
            snapshot = fetch_market_snapshot_cached()
            cache_api_payload(
                db,
                cache_key=MARKET_SNAPSHOT_CACHE_KEY,
                payload=snapshot,
                source="ngxpulse_market_snapshot",
            )
            cache_entries += 1
        except NgxFetchError as exc:
            record_sync_log(
                db,
                status="warning",
                source=REFERENCE_CACHE_SYNC_SOURCE,
                message=f"Market snapshot cache refresh failed: {exc}",
            )
        try:
            stories = fetch_market_news_cached(6)
            cache_api_payload(
                db,
                cache_key=market_news_cache_key(6),
                payload=stories,
                source="ngxpulse_market_news",
            )
            cache_entries += 1
        except NgxFetchError as exc:
            record_sync_log(
                db,
                status="warning",
                source=REFERENCE_CACHE_SYNC_SOURCE,
                message=f"Market news cache refresh failed: {exc}",
            )

    for stock in stocks:
        if stock.supports_history:
            history_rows += upsert_stock_history(
                db,
                stock.symbol,
                stock.ngx_id,
                since=None,
                allow_legacy_fallback=not get_settings().ngxpulse_enabled,
            )
        if not get_settings().ngxpulse_enabled:
            continue
        try:
            cache_api_payload(
                db,
                cache_key=dividend_cache_key(stock.symbol, 10),
                payload=fetch_dividend_history_cached(stock.symbol, 10),
                source="ngxpulse_dividends",
            )
            cache_entries += 1
        except NgxFetchError:
            pass
        try:
            cache_api_payload(
                db,
                cache_key=disclosure_cache_key(stock.symbol, 8),
                payload=fetch_disclosures_cached(stock.symbol, 8),
                source="ngxpulse_disclosures",
            )
            cache_entries += 1
        except NgxFetchError:
            pass
        if stock.ngx_id:
            try:
                cache_api_payload(
                    db,
                    cache_key=company_news_cache_key(stock.symbol, 6),
                    payload=fetch_company_news_cached(stock.ngx_id)[:6],
                    source="ngx_company_news",
                )
                cache_entries += 1
            except NgxFetchError:
                pass

    record_sync_log(
        db,
        status="success",
        source=REFERENCE_CACHE_SYNC_SOURCE,
        stocks_upserted=len(stocks),
        history_rows_upserted=history_rows,
        message=f"Refreshed {cache_entries} cached API payloads.",
    )
    db.commit()
    return history_rows, cache_entries
