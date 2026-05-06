import base64
import asyncio
import logging
import secrets
from contextlib import suppress
from datetime import date, datetime, timedelta, timezone

from dateutil.relativedelta import relativedelta
from fastapi import Depends, FastAPI, File, Form, HTTPException, Query, Request, Response, UploadFile, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from sqlalchemy import desc, func, select, text
from sqlalchemy.orm import Session, selectinload

from .auth import create_access_token, get_current_superuser, get_current_user, hash_password, verify_password
from .database import Base, SessionLocal, engine, get_db
from .legal import render_account_deletion_html, render_privacy_policy_html
from .models import AccountDeletionRequest, PortfolioHolding, PushDeviceToken, Stock, StockPrice, User
from .notifications import portfolio_report_pdf, send_email
from .ngx_client import (
    NgxFetchError,
    discover_stock_ngx_id,
    fetch_all_stocks_from_ngx_cached,
    fetch_stock_logo,
)
from .push import PushDeliveryError, dispatch_market_price_alerts, remove_push_token, send_push_message, upsert_push_token
from .schemas import (
    AccountDeleteRequest,
    AccountDeletionRequestCreate,
    AccountDeletionRequestOut,
    CompanyNewsOut,
    DisclosureOut,
    DividendHistoryOut,
    HoldingOut,
    HoldingUpsert,
    LoginRequest,
    MarketIdeasOut,
    MarketIdeaOut,
    MarketLeadersOut,
    MarketNewsOut,
    MarketSnapshotOut,
    MarketStatusOut,
    MessageResponse,
    PasswordChangeRequest,
    PasswordResetConfirm,
    PasswordResetRequest,
    ProfileUpdate,
    PushStatusOut,
    PushTestRequest,
    PushTokenDelete,
    PushTokenUpsert,
    RegisterRequest,
    StockOut,
    StockDetailOut,
    StockPriceOut,
    SyncLogOut,
    SyncResult,
    SyncStatusOut,
    TokenResponse,
    UserOut,
)
from .services import (
    delete_holding,
    get_cached_company_news,
    get_cached_disclosures,
    get_cached_dividend_history,
    get_cached_market_news,
    get_cached_market_snapshot,
    get_cached_market_status,
    holding_to_dict,
    record_sync_log,
    reference_cache_refresh_due,
    refresh_reference_caches,
    refresh_market_status,
    stock_history_query,
    sync_logs_query,
    sync_status,
    sync_stocks,
    upsert_holding,
    upsert_stock_history,
)
from .settings import get_settings


settings = get_settings()
logger = logging.getLogger("ngx_dash")
stock_sync_task: asyncio.Task | None = None
app = FastAPI(title=settings.app_name)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

MARKET_IDEAS_DISCLAIMER = (
    "Stockfolio NG highlights data-driven watchlist ideas only. "
    "It is not a financial adviser app. Contact your broker for detailed analysis."
)


def stock_history_is_stale(rows: list) -> bool:
    if not rows:
        return True

    latest_updated_at = max((row.updated_at for row in rows if row.updated_at), default=None)
    if latest_updated_at is None:
        return True
    if latest_updated_at.tzinfo is None:
        latest_updated_at = latest_updated_at.replace(tzinfo=timezone.utc)

    refresh_after = timedelta(seconds=max(1, settings.stock_sync_interval_seconds))
    return datetime.now(timezone.utc) - latest_updated_at > refresh_after


def stock_history_needs_backfill(
    rows: list,
    *,
    normalized_range: str | None,
    since: date | None,
    limit_trading_days: int | None,
) -> bool:
    if not rows:
        return True
    if any(row.open_price is None for row in rows):
        return True
    if stock_history_is_stale(rows):
        return True
    if normalized_range == "all":
        oldest = min((row.trade_date for row in rows), default=None)
        if oldest is None:
            return True
        return len(rows) < 90 or oldest > date.today() - relativedelta(months=6)
    if limit_trading_days is not None and limit_trading_days > 0:
        return len(rows) < limit_trading_days
    if since is None:
        return False
    oldest = min((row.trade_date for row in rows), default=None)
    if oldest is None:
        return True
    grace_days = 5 if normalized_range in {"1w", "1m"} else 14
    return oldest > since + timedelta(days=grace_days)


def intraday_leader_payload(stock: Stock) -> dict | None:
    current_price = float(stock.last_price) if stock.last_price is not None else None
    opening_price = float(stock.open_price) if stock.open_price is not None else None
    if current_price is None or opening_price is None or opening_price <= 0:
        return None

    change = current_price - opening_price
    percent_change = (change / opening_price) * 100
    payload = StockOut.model_validate(stock).model_dump()
    payload["change"] = change
    payload["percent_change"] = percent_change
    return payload


def intraday_leader_payload_from_dict(stock: dict) -> dict | None:
    current_price = float(stock["last_price"]) if stock.get("last_price") is not None else None
    opening_price = float(stock["open_price"]) if stock.get("open_price") is not None else None
    if current_price is None or opening_price is None or opening_price <= 0:
        return None

    payload = dict(stock)
    payload["change"] = current_price - opening_price
    payload["percent_change"] = (payload["change"] / opening_price) * 100
    payload.setdefault("source", "ngx_doclib_live")
    return payload


def market_leaders_payload(db: Session, limit: int) -> dict:
    stocks = db.scalars(
        select(Stock)
        .where(Stock.last_price.is_not(None), Stock.open_price.is_not(None))
        .order_by(Stock.symbol)
    ).all()
    ranked = [payload for stock in stocks if (payload := intraday_leader_payload(stock)) is not None]
    if len(ranked) < max(2, limit):
        try:
            live_ranked = [
                payload
                for stock in fetch_all_stocks_from_ngx_cached()
                if (payload := intraday_leader_payload_from_dict(stock)) is not None
            ]
        except NgxFetchError as exc:
            logger.warning("Live market leaders fallback failed: %s", exc)
        else:
            if live_ranked:
                ranked = live_ranked
    ranked.sort(key=lambda item: (item["percent_change"], item["symbol"]), reverse=True)
    return {
        "top_movers": ranked[:limit],
        "top_losers": sorted(ranked, key=lambda item: (item["percent_change"], item["symbol"]))[:limit],
    }


def _percentile(sorted_values: list[float], value: float | None) -> float:
    if value is None or not sorted_values:
        return 0.0
    less_or_equal = 0
    for candidate in sorted_values:
        if candidate <= value:
            less_or_equal += 1
    return less_or_equal / len(sorted_values)


def market_ideas_payload(db: Session, limit: int) -> dict:
    stocks = list(
        db.scalars(
            select(Stock)
            .where(Stock.last_price.is_not(None), Stock.open_price.is_not(None))
            .order_by(Stock.symbol)
        ).all()
    )
    if not stocks:
        return {
            "disclaimer": MARKET_IDEAS_DISCLAIMER,
            "generated_at": datetime.now(timezone.utc),
            "stocks_analyzed": 0,
            "ideas": [],
        }

    one_year_since = date.today() - relativedelta(years=1)
    history_rows = list(
        db.scalars(
            select(StockPrice)
            .where(StockPrice.trade_date >= one_year_since)
            .order_by(StockPrice.stock_symbol, StockPrice.trade_date)
        ).all()
    )
    history_by_symbol: dict[str, tuple[float, float]] = {}
    for row in history_rows:
        symbol = row.stock_symbol
        close_price = float(row.close_price)
        if symbol not in history_by_symbol:
            history_by_symbol[symbol] = (close_price, close_price)
        else:
            first_close, _ = history_by_symbol[symbol]
            history_by_symbol[symbol] = (first_close, close_price)

    volumes = sorted(float(stock.volume) for stock in stocks if stock.volume is not None and float(stock.volume) > 0)
    market_caps = sorted(
        float(stock.market_cap) for stock in stocks if stock.market_cap is not None and float(stock.market_cap) > 0
    )

    candidates: list[dict] = []
    for stock in stocks:
        current_price = float(stock.last_price) if stock.last_price is not None else None
        opening_price = float(stock.open_price) if stock.open_price is not None else None
        if current_price is None or opening_price is None or opening_price <= 0:
            continue

        intraday_change = ((current_price - opening_price) / opening_price) * 100
        volume_score = _percentile(volumes, float(stock.volume) if stock.volume is not None else None)
        market_cap_score = _percentile(market_caps, float(stock.market_cap) if stock.market_cap is not None else None)
        margin_value = float(stock.margin) if stock.margin is not None else None
        margin_score = 0.0 if margin_value is None else max(0.0, 1.0 - min(margin_value, 10.0) / 10.0)
        close_strength = 0.0
        if stock.previous_close is not None and current_price > float(stock.previous_close):
            close_strength = 1.0
        growth_tuple = history_by_symbol.get(stock.symbol)
        one_year_growth_percent: float | None = None
        if growth_tuple is not None and growth_tuple[0] > 0:
            one_year_growth_percent = ((growth_tuple[1] - growth_tuple[0]) / growth_tuple[0]) * 100

        score = max(0.0, min(intraday_change, 10.0)) * 4.0
        score += volume_score * 25.0
        score += market_cap_score * 15.0
        score += margin_score * 10.0
        score += close_strength * 10.0
        if one_year_growth_percent is not None:
            score += max(-10.0, min(one_year_growth_percent, 40.0)) * 0.7

        rationale: list[str] = []
        if intraday_change > 0:
            rationale.append(f"Positive intraday momentum of {intraday_change:.2f}% from the open.")
        if one_year_growth_percent is not None:
            rationale.append(f"One-year price growth is {one_year_growth_percent:.2f}%.")
        if volume_score >= 0.75:
            rationale.append("Trading volume is in the top quartile of the tracked market.")
        if market_cap_score >= 0.75:
            rationale.append("Market cap ranks in the upper tier of the synced universe.")
        if margin_value is not None and margin_value <= 4:
            rationale.append(f"Margin is relatively tight at {margin_value:.2f}%.")
        if close_strength > 0:
            rationale.append("Current price is holding above the previous close.")
        if stock.sector:
            rationale.append(f"Sector: {stock.sector}.")

        candidates.append(
            {
                "stock": StockOut.model_validate(stock).model_dump(),
                "score": round(score, 2),
                "one_year_growth_percent": None if one_year_growth_percent is None else round(one_year_growth_percent, 2),
                "stocks_analyzed": len(stocks),
                "rationale": rationale[:4],
                "web_summary": None,
                "price_to_earnings_ratio": None,
                "price_to_book_ratio": None,
                "fundamental_note": "P/E and P/B ratios are not yet available from the current synced source.",
                "ngx_id": stock.ngx_id,
            }
        )

    candidates.sort(key=lambda item: (item["score"], item["stock"]["symbol"]), reverse=True)
    enriched: list[dict] = []
    for candidate in candidates[: max(limit * 2, 6)]:
        ngx_id = candidate.pop("ngx_id", None)
        if ngx_id:
            try:
                news = fetch_company_news_cached(ngx_id)
            except NgxFetchError as exc:
                logger.warning("Company news fetch failed while building ideas for %s: %s", candidate["stock"]["symbol"], exc)
            else:
                if news:
                    latest = news[0]
                    candidate["web_summary"] = latest.get("title") or latest.get("submission_type")
                    candidate["score"] = round(candidate["score"] + 5.0, 2)
                    candidate["rationale"] = [
                        *candidate["rationale"],
                        "Recent company update/disclosure is available from NGX sources.",
                    ][:5]
                    latest_title = (latest.get("title") or "").lower()
                    if any(
                        keyword in latest_title
                        for keyword in ("audited", "annual report", "financial statement", "q1", "q2", "q3", "q4")
                    ):
                        candidate["rationale"] = [
                            *candidate["rationale"],
                            "Latest filing references recent financial statements from the previous reporting period.",
                        ][:5]
        enriched.append(candidate)

    enriched.sort(key=lambda item: (item["score"], item["stock"]["symbol"]), reverse=True)
    return {
        "disclaimer": MARKET_IDEAS_DISCLAIMER,
        "generated_at": datetime.now(timezone.utc),
        "stocks_analyzed": len(stocks),
        "ideas": enriched[:limit],
    }


def ensure_stock_ngx_id(db: Session, stock: Stock) -> str | None:
    if stock.ngx_id:
        return stock.ngx_id

    try:
        discovered = discover_stock_ngx_id(stock.symbol)
    except NgxFetchError as exc:
        logger.warning("NGX chart id discovery failed for %s: %s", stock.symbol, exc)
        return None

    if discovered:
        stock.ngx_id = discovered
        db.commit()
        db.refresh(stock)
    return stock.ngx_id


def stock_history_source(stock: Stock) -> str | None:
    if settings.ngxpulse_enabled:
        return "ngxpulse_history"
    if stock.ngx_id:
        return "ngx_chart"
    return None


def normalize_history_range(range_value: str | None) -> str | None:
    if range_value is None:
        return None
    normalized = (
        range_value.strip().lower().replace(" ", "").replace("-", "").replace("_", "")
    )
    if not normalized:
        return None
    aliases = {
        "1d": "1d",
        "1day": "1d",
        "day": "1d",
        "5d": "5d",
        "5day": "5d",
        "5days": "5d",
        "1w": "1w",
        "week": "1w",
        "1week": "1w",
        "1m": "1m",
        "month": "1m",
        "1month": "1m",
        "3m": "3m",
        "3month": "3m",
        "3months": "3m",
        "6m": "6m",
        "6month": "6m",
        "6months": "6m",
        "1y": "1y",
        "year": "1y",
        "1year": "1y",
        "all": "all",
        "alltime": "all",
        "max": "all",
    }
    return aliases.get(normalized)


def resolve_history_window(
    *,
    range_value: str | None,
    months: int,
) -> tuple[date | None, int | None]:
    normalized_range = normalize_history_range(range_value)
    today = date.today()
    if normalized_range == "1d":
        return today - timedelta(days=21), 1
    if normalized_range == "5d":
        return today - timedelta(days=30), 5
    if normalized_range == "1w":
        return today - timedelta(days=10), None
    if normalized_range == "1m":
        return today - relativedelta(months=1), None
    if normalized_range == "3m":
        return today - relativedelta(months=3), None
    if normalized_range == "6m":
        return today - relativedelta(months=6), None
    if normalized_range == "1y":
        return today - relativedelta(years=1), None
    if normalized_range == "all":
        return None, None
    return today - relativedelta(months=months), None


async def background_stock_sync_loop() -> None:
    interval = max(1, settings.stock_sync_interval_seconds)
    while True:
        db = SessionLocal()
        try:
            await asyncio.to_thread(sync_stocks, db, False)
            await asyncio.to_thread(refresh_market_status, db)
            if await asyncio.to_thread(reference_cache_refresh_due, db):
                await asyncio.to_thread(refresh_reference_caches, db)
            if settings.push_enabled:
                result = await asyncio.to_thread(dispatch_market_price_alerts, db, settings)
                if result["market_open_alerts_sent"] or result["stock_alerts_sent"]:
                    logger.info(
                        "Sent %s market-open alerts and %s stock alerts to %s device tokens",
                        result["market_open_alerts_sent"],
                        result["stock_alerts_sent"],
                        result["tokens_sent"],
                    )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("Background stock sync failed")
            with suppress(Exception):
                record_sync_log(
                    db,
                    status="failed",
                    source="background_sync",
                    message=f"Background stock sync failed: {exc}",
                )
                db.commit()
        finally:
            db.close()
        await asyncio.sleep(interval)


def ensure_runtime_schema() -> None:
    with engine.begin() as conn:
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS is_superuser BOOLEAN NOT NULL DEFAULT false"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_image_url TEXT"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR(64)"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS address VARCHAR(255)"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS city VARCHAR(128)"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS country VARCHAR(128)"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT false"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verification_token VARCHAR(128)"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verification_sent_at TIMESTAMPTZ"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS password_reset_token VARCHAR(128)"))
        conn.execute(text("ALTER TABLE users ADD COLUMN IF NOT EXISTS password_reset_sent_at TIMESTAMPTZ"))
        conn.execute(
            text("CREATE INDEX IF NOT EXISTS ix_users_email_verification_token ON users(email_verification_token)")
        )
        conn.execute(text("CREATE INDEX IF NOT EXISTS ix_users_password_reset_token ON users(password_reset_token)"))
        conn.execute(
            text(
                """
                CREATE TABLE IF NOT EXISTS market_status (
                    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                    status VARCHAR(128) NOT NULL,
                    source VARCHAR(64) NOT NULL DEFAULT 'ngx_doclib',
                    message TEXT,
                    raw_payload TEXT,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """
            )
        )
        conn.execute(text("CREATE INDEX IF NOT EXISTS ix_market_status_status ON market_status(status)"))
        conn.execute(
            text(
                """
                UPDATE users
                SET is_superuser = true
                WHERE id = (SELECT id FROM users ORDER BY id LIMIT 1)
                  AND NOT EXISTS (SELECT 1 FROM users WHERE is_superuser = true)
                """
            )
        )


@app.on_event("startup")
async def startup() -> None:
    global stock_sync_task
    Base.metadata.create_all(bind=engine)
    ensure_runtime_schema()
    if settings.enable_background_stock_sync:
        stock_sync_task = asyncio.create_task(background_stock_sync_loop())


@app.on_event("shutdown")
async def shutdown() -> None:
    if stock_sync_task is None:
        return
    stock_sync_task.cancel()
    with suppress(asyncio.CancelledError):
        await stock_sync_task


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/public/stocks/{symbol}/logo", include_in_schema=False)
def public_stock_logo(symbol: str) -> Response:
    try:
        logo = fetch_stock_logo(symbol)
    except NgxFetchError as exc:
        logger.warning("Stock logo fetch failed for %s: %s", symbol, exc)
        raise HTTPException(status_code=404, detail="Logo not found") from exc

    if logo is None:
        raise HTTPException(status_code=404, detail="Logo not found")

    content, media_type = logo
    return Response(
        content=content,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=86400"},
    )


@app.get("/public/market/status", response_model=MarketStatusOut, include_in_schema=False)
def public_market_status(db: Session = Depends(get_db)) -> dict:
    return get_cached_market_status(db)


@app.get("/public/market/leaders", response_model=MarketLeadersOut, include_in_schema=False)
def public_market_leaders(
    limit: int = Query(default=6, ge=1, le=20),
    db: Session = Depends(get_db),
) -> dict:
    return market_leaders_payload(db, limit)


@app.get("/public/market/news", response_model=list[MarketNewsOut], include_in_schema=False)
def public_market_news(limit: int = Query(default=6, ge=1, le=20), db: Session = Depends(get_db)) -> list[dict]:
    if not settings.ngxpulse_enabled:
        return []
    return get_cached_market_news(db, limit)


@app.get("/public/privacy-policy", include_in_schema=False, response_class=HTMLResponse)
def public_privacy_policy(request: Request) -> HTMLResponse:
    privacy_url = str(request.url_for("public_privacy_policy"))
    deletion_url = str(request.url_for("public_account_deletion"))
    return HTMLResponse(render_privacy_policy_html(settings, privacy_url=privacy_url, deletion_url=deletion_url))


@app.get("/public/account-deletion", include_in_schema=False, response_class=HTMLResponse, name="public_account_deletion")
def public_account_deletion(request: Request) -> HTMLResponse:
    return HTMLResponse(
        render_account_deletion_html(
            settings,
            post_url=str(request.url_for("submit_account_deletion_request")),
            privacy_url=str(request.url_for("public_privacy_policy")),
        )
    )


@app.post(
    "/public/account-deletion-request",
    include_in_schema=False,
    response_model=MessageResponse,
    name="submit_account_deletion_request",
)
def submit_account_deletion_request(
    payload: AccountDeletionRequestCreate,
    db: Session = Depends(get_db),
) -> MessageResponse:
    request_row = AccountDeletionRequest(
        email=payload.email.lower(),
        reason=payload.reason.strip() if payload.reason else None,
        source="web",
        status="pending",
    )
    db.add(request_row)
    db.commit()
    db.refresh(request_row)

    if settings.email_enabled and settings.contact_email:
        try:
            send_email(
                settings,
                to_email=settings.contact_email,
                subject=f"{settings.app_name} account deletion request",
                body=(
                    "A user submitted an external account deletion request.\n\n"
                    f"Email: {request_row.email}\n"
                    f"Reason: {request_row.reason or 'Not provided'}\n"
                    f"Request ID: {request_row.id}"
                ),
            )
        except Exception as exc:
            logger.warning("Account deletion request email notification failed: %s", exc)

    return MessageResponse(
        message=(
            "Your deletion request has been recorded. "
            "If this email matches an account in Stockfolio NG, the request can now be processed."
        )
    )


def _new_email_verification_token() -> str:
    return secrets.token_urlsafe(32)


def _verification_url(token: str) -> str:
    base_url = settings.frontend_base_url.rstrip("/")
    return f"{base_url}/?verify_email_token={token}"


def _new_password_reset_token() -> str:
    return secrets.token_urlsafe(32)


def _password_reset_url(token: str) -> str:
    base_url = settings.frontend_base_url.rstrip("/")
    return f"{base_url}/?reset_password_token={token}"


@app.post("/auth/register", response_model=UserOut, status_code=status.HTTP_201_CREATED)
def register(payload: RegisterRequest, db: Session = Depends(get_db)) -> User:
    existing = db.scalar(select(User).where(User.email == payload.email.lower()))
    if existing:
        raise HTTPException(status_code=409, detail="Email is already registered")
    user_count = db.scalar(select(func.count()).select_from(User)) or 0
    email = payload.email.lower()
    user = User(
        email=email,
        full_name=payload.full_name,
        password_hash=hash_password(payload.password),
        is_superuser=user_count == 0 or email in settings.admin_email_list,
        email_verified=False,
        email_verification_token=_new_email_verification_token(),
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


@app.post("/auth/login", response_model=TokenResponse)
def login(payload: LoginRequest, db: Session = Depends(get_db)) -> TokenResponse:
    user = db.scalar(select(User).where(User.email == payload.email.lower()))
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    return TokenResponse(access_token=create_access_token(user.id))


@app.get("/auth/verify-email", response_model=MessageResponse)
def verify_email(token: str, db: Session = Depends(get_db)) -> MessageResponse:
    user = db.scalar(select(User).where(User.email_verification_token == token))
    if user is None:
        raise HTTPException(status_code=404, detail="Verification link is invalid or expired")

    user.email_verified = True
    user.email_verification_token = None
    user.email_verification_sent_at = None
    db.commit()
    return MessageResponse(message="Email address verified.")


@app.post("/auth/forgot-password", response_model=MessageResponse)
def forgot_password(payload: PasswordResetRequest, db: Session = Depends(get_db)) -> MessageResponse:
    user = db.scalar(select(User).where(User.email == payload.email.lower()))
    generic_message = "If that email is registered, a password reset link has been sent."
    if user is None:
        return MessageResponse(message=generic_message)

    user.password_reset_token = _new_password_reset_token()
    user.password_reset_sent_at = datetime.now(timezone.utc)
    db.commit()
    reset_url = _password_reset_url(user.password_reset_token)

    if not settings.email_enabled:
        return MessageResponse(
            message="Email is not configured yet. Password reset link generated for testing.",
            verification_url=reset_url,
        )

    try:
        send_email(
            settings,
            to_email=user.email,
            subject="Reset your Stockfolio NG password",
            body=(
                f"Hello {user.full_name or user.email},\n\n"
                "Use this link to reset your password:\n"
                f"{reset_url}\n\n"
                "If you did not request this, you can ignore this email."
            ),
        )
    except Exception as exc:
        logger.warning("Password reset delivery failed via %s: %s", settings.email_provider, exc)
        return MessageResponse(message=f"Could not send reset email yet: {exc}")

    return MessageResponse(message=generic_message)


@app.post("/auth/reset-password", response_model=MessageResponse)
def reset_password(payload: PasswordResetConfirm, db: Session = Depends(get_db)) -> MessageResponse:
    user = db.scalar(select(User).where(User.password_reset_token == payload.token))
    if user is None or user.password_reset_sent_at is None:
        raise HTTPException(status_code=404, detail="Password reset link is invalid or expired")

    sent_at = user.password_reset_sent_at
    if sent_at.tzinfo is None:
        sent_at = sent_at.replace(tzinfo=timezone.utc)
    if datetime.now(timezone.utc) - sent_at > timedelta(hours=2):
        user.password_reset_token = None
        user.password_reset_sent_at = None
        db.commit()
        raise HTTPException(status_code=400, detail="Password reset link has expired")

    user.password_hash = hash_password(payload.new_password)
    user.password_reset_token = None
    user.password_reset_sent_at = None
    db.commit()
    return MessageResponse(message="Password reset successful. You can now sign in.")


@app.get("/me", response_model=UserOut)
def me(user: User = Depends(get_current_user)) -> User:
    return user


@app.put("/me", response_model=UserOut)
def update_me(
    payload: ProfileUpdate,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> User:
    user.full_name = payload.full_name.strip() if payload.full_name else None
    user.phone = payload.phone.strip() if payload.phone else None
    user.address = payload.address.strip() if payload.address else None
    user.city = payload.city.strip() if payload.city else None
    user.country = payload.country.strip() if payload.country else None
    db.commit()
    db.refresh(user)
    return user


@app.post("/me/profile-image", response_model=UserOut)
async def upload_profile_image(
    file: UploadFile = File(...),
    mime_type: str | None = Form(default=None),
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> User:
    effective_mime_type = (mime_type or file.content_type or "").strip().lower()
    if not effective_mime_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Please upload an image file.")

    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Uploaded image is empty.")
    if len(content) > 2_000_000:
        raise HTTPException(status_code=400, detail="Profile image must be 2MB or smaller.")

    encoded = base64.b64encode(content).decode("ascii")
    user.profile_image_url = f"data:{effective_mime_type};base64,{encoded}"
    db.commit()
    db.refresh(user)
    return user


@app.delete("/me/profile-image", response_model=UserOut)
def delete_profile_image(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> User:
    user.profile_image_url = None
    db.commit()
    db.refresh(user)
    return user


@app.post("/me/password", response_model=MessageResponse)
def change_password(
    payload: PasswordChangeRequest,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> MessageResponse:
    if not verify_password(payload.current_password, user.password_hash):
        raise HTTPException(status_code=400, detail="Current password is incorrect")
    user.password_hash = hash_password(payload.new_password)
    db.commit()
    return MessageResponse(message="Password updated.")


@app.post("/me/delete-account", response_model=MessageResponse)
def delete_account(
    payload: AccountDeleteRequest,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> MessageResponse:
    if not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=400, detail="Current password is incorrect")

    email = user.email
    db.delete(user)
    db.commit()
    return MessageResponse(message=f"Account {email} and associated portfolio data were deleted.")


@app.post("/me/email-verification", response_model=MessageResponse)
def request_email_verification(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> MessageResponse:
    if user.email_verified:
        return MessageResponse(message="Email address is already verified.")

    user.email_verification_token = _new_email_verification_token()
    user.email_verification_sent_at = datetime.now(timezone.utc)
    db.commit()
    verification_url = _verification_url(user.email_verification_token)

    if not settings.email_enabled:
        return MessageResponse(
            message="Email is not configured yet. Verification link generated for testing.",
            verification_url=verification_url,
        )

    try:
        logger.info("Sending email verification via %s", settings.email_provider)
        send_email(
            settings,
            to_email=user.email,
            subject="Verify your Stockfolio email",
            body=(
                f"Hello {user.full_name or user.email},\n\n"
                "Use this link to verify your email address:\n"
                f"{verification_url}\n\n"
                "If you did not request this, you can ignore this email."
            ),
        )
    except Exception as exc:
        logger.warning("Email verification delivery failed via %s: %s", settings.email_provider, exc)
        return MessageResponse(message=f"Could not send verification email yet: {exc}")

    return MessageResponse(message="Verification email sent.")


@app.post("/me/portfolio-report/email", response_model=MessageResponse)
def email_portfolio_report(
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> MessageResponse:
    holdings = db.scalars(
        select(PortfolioHolding)
        .options(selectinload(PortfolioHolding.stock))
        .where(PortfolioHolding.user_id == user.id)
        .order_by(PortfolioHolding.stock_symbol)
    ).all()
    holding_rows = [holding_to_dict(holding) for holding in holdings]
    pdf = portfolio_report_pdf(user, holding_rows)

    if not settings.email_enabled:
        return MessageResponse(message="Portfolio report generated, but email is not configured on the server.")

    try:
        logger.info("Sending portfolio report via %s", settings.email_provider)
        send_email(
            settings,
            to_email=user.email,
            subject="Your Stockfolio Report",
            body=(
                f"Hello {user.full_name or user.email},\n\n"
                "Your latest NGX investment portfolio report is attached as a PDF."
            ),
            attachment=("ngx-portfolio-report.pdf", pdf, "application/pdf"),
        )
    except Exception as exc:
        logger.warning("Portfolio report email delivery failed via %s: %s", settings.email_provider, exc)
        return MessageResponse(message=f"Could not email portfolio report yet: {exc}")

    return MessageResponse(message=f"Portfolio report emailed to {user.email}.")


@app.post("/me/push-tokens", response_model=MessageResponse)
def register_push_token(
    payload: PushTokenUpsert,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> MessageResponse:
    upsert_push_token(
        db,
        user,
        token=payload.token,
        platform=payload.platform,
        device_label=payload.device_label,
    )
    return MessageResponse(message="Push token registered.")


@app.delete("/me/push-tokens", status_code=status.HTTP_204_NO_CONTENT)
def unregister_push_token(
    payload: PushTokenDelete,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> Response:
    removed = remove_push_token(db, user, token=payload.token)
    if not removed:
        raise HTTPException(status_code=404, detail="Push token not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/market/status", response_model=MarketStatusOut)
def get_market_status(db: Session = Depends(get_db), _: User = Depends(get_current_user)) -> dict:
    return get_cached_market_status(db)


@app.get("/market/snapshot", response_model=MarketSnapshotOut)
def get_market_snapshot(db: Session = Depends(get_db), _: User = Depends(get_current_user)) -> dict:
    snapshot = get_cached_market_snapshot(db)
    if snapshot is None:
        raise HTTPException(status_code=503, detail="Market snapshot is not available yet")
    return snapshot


@app.get("/market/leaders", response_model=MarketLeadersOut)
def get_market_leaders(
    limit: int = Query(default=5, ge=1, le=20),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> dict:
    return market_leaders_payload(db, limit)


@app.get("/market/news", response_model=list[MarketNewsOut])
def get_market_news(
    limit: int = Query(default=6, ge=1, le=20),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> list[dict]:
    if not settings.ngxpulse_enabled:
        return []
    return get_cached_market_news(db, limit)


@app.get("/market/ideas", response_model=MarketIdeasOut)
def get_market_ideas(
    limit: int = Query(default=5, ge=1, le=10),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> dict:
    return market_ideas_payload(db, limit)


@app.get("/stocks", response_model=list[StockOut])
def list_stocks(
    search: str | None = None,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> list[Stock]:
    query = select(Stock).order_by(Stock.symbol)
    if search:
        term = f"%{search.strip()}%"
        query = query.where((Stock.symbol.ilike(term)) | (Stock.name.ilike(term)))
    return list(db.scalars(query).all())


@app.get("/stocks/{symbol}", response_model=StockOut)
def get_stock(symbol: str, db: Session = Depends(get_db), _: User = Depends(get_current_user)) -> Stock:
    stock = db.get(Stock, symbol.strip().upper())
    if stock is None:
        raise HTTPException(status_code=404, detail="Stock not found")
    return stock


@app.get("/stocks/{symbol}/company-news", response_model=list[CompanyNewsOut])
def get_stock_company_news(
    symbol: str,
    limit: int = Query(default=6, ge=1, le=20),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> list[dict]:
    stock = db.get(Stock, symbol.strip().upper())
    if stock is None:
        raise HTTPException(status_code=404, detail="Stock not found")
    ngx_id = ensure_stock_ngx_id(db, stock)
    if not ngx_id:
        return []
    return get_cached_company_news(db, stock.symbol, ngx_id, limit)


@app.get("/stocks/{symbol}/dividends", response_model=list[DividendHistoryOut])
def get_stock_dividends(
    symbol: str,
    limit: int = Query(default=8, ge=1, le=50),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> list[dict]:
    stock = db.get(Stock, symbol.strip().upper())
    if stock is None:
        raise HTTPException(status_code=404, detail="Stock not found")
    if not settings.ngxpulse_enabled:
        return []
    return get_cached_dividend_history(db, stock.symbol, limit)


@app.get("/stocks/{symbol}/disclosures", response_model=list[DisclosureOut])
def get_stock_disclosures(
    symbol: str,
    limit: int = Query(default=8, ge=1, le=50),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> list[dict]:
    stock = db.get(Stock, symbol.strip().upper())
    if stock is None:
        raise HTTPException(status_code=404, detail="Stock not found")
    if not settings.ngxpulse_enabled:
        return []
    return get_cached_disclosures(db, stock.symbol, limit)


@app.get("/stocks/{symbol}/history", response_model=list[StockPriceOut])
def get_stock_history(
    symbol: str,
    range: str | None = Query(default=None),
    months: int = Query(default=12, ge=1, le=120),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    stock = db.get(Stock, symbol.strip().upper())
    if stock is None:
        raise HTTPException(status_code=404, detail="Stock not found")

    ngx_id = stock.ngx_id if settings.ngxpulse_enabled else ensure_stock_ngx_id(db, stock)
    normalized_range = normalize_history_range(range)
    since, limit_trading_days = resolve_history_window(range_value=range, months=months)
    rows = stock_history_query(db, symbol, since, limit_trading_days)
    fetch_since = None if normalized_range == "all" else since
    if stock.supports_history and stock_history_needs_backfill(
        rows,
        normalized_range=normalized_range,
        since=since,
        limit_trading_days=limit_trading_days,
    ):
        upsert_stock_history(db, stock.symbol, ngx_id, since=fetch_since)
        db.commit()
        rows = stock_history_query(db, symbol, since, limit_trading_days)
    return rows


def build_stock_detail(
    symbol: str,
    range: str | None = Query(default=None),
    months: int = Query(default=12, ge=1, le=120),
    news_limit: int = Query(default=6, ge=1, le=20),
    db: Session = Depends(get_db),
) -> dict:
    stock = db.get(Stock, symbol.strip().upper())
    if stock is None:
        raise HTTPException(status_code=404, detail="Stock not found")

    ngx_id = ensure_stock_ngx_id(db, stock)
    normalized_range = normalize_history_range(range)
    since, limit_trading_days = resolve_history_window(range_value=range, months=months)
    rows = stock_history_query(db, symbol, since, limit_trading_days)
    fetch_since = None if normalized_range == "all" else since
    if stock.supports_history and stock_history_needs_backfill(
        rows,
        normalized_range=normalized_range,
        since=since,
        limit_trading_days=limit_trading_days,
    ):
        upsert_stock_history(db, stock.symbol, ngx_id, since=fetch_since)
        db.commit()
        db.refresh(stock)
        rows = stock_history_query(db, symbol, since, limit_trading_days)

    market_snapshot = get_cached_market_snapshot(db)

    news = get_cached_company_news(db, stock.symbol, ngx_id, news_limit) if ngx_id else []

    dividends: list[dict] = []
    disclosures: list[dict] = []
    if settings.ngxpulse_enabled:
        dividends = get_cached_dividend_history(db, stock.symbol, 10)
        disclosures = get_cached_disclosures(db, stock.symbol, news_limit)

    return {
        "stock": stock,
        "history": rows,
        "market_snapshot": market_snapshot,
        "history_source": stock_history_source(stock),
        "news": news,
        "dividends": dividends,
        "disclosures": disclosures,
    }


@app.get("/public/stocks/{symbol}/detail", response_model=StockDetailOut, include_in_schema=False)
def get_public_stock_detail(
    symbol: str,
    range: str | None = Query(default=None),
    months: int = Query(default=12, ge=1, le=120),
    news_limit: int = Query(default=6, ge=1, le=20),
    db: Session = Depends(get_db),
) -> dict:
    return build_stock_detail(symbol, range, months, news_limit, db)


@app.get("/stocks/{symbol}/detail", response_model=StockDetailOut)
def get_stock_detail(
    symbol: str,
    range: str | None = Query(default=None),
    months: int = Query(default=12, ge=1, le=120),
    news_limit: int = Query(default=6, ge=1, le=20),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
) -> dict:
    return build_stock_detail(symbol, range, months, news_limit, db)


@app.post("/admin/sync/stocks", response_model=SyncResult)
def run_stock_sync(
    include_history: bool = False,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_superuser),
) -> SyncResult:
    source, stock_count, history_count, sync_state, message = sync_stocks(db, include_history=include_history)
    return SyncResult(
        source=source,
        stocks_upserted=stock_count,
        history_rows_upserted=history_count,
        status=sync_state,
        message=message,
    )


@app.get("/admin/sync/status", response_model=SyncStatusOut)
def get_sync_status(db: Session = Depends(get_db), _: User = Depends(get_current_superuser)) -> dict:
    return sync_status(db)


@app.get("/admin/sync/logs", response_model=list[SyncLogOut])
def get_sync_logs(
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_superuser),
):
    return sync_logs_query(db, limit)


@app.get("/admin/email/status")
def get_email_status(_: User = Depends(get_current_superuser)) -> dict:
    return {
        "enabled": settings.email_enabled,
        "provider": settings.email_provider,
        "has_resend_api_key": bool(settings.resend_api_key),
        "has_resend_from_email": bool(settings.resend_from_email),
        "has_smtp_host": bool(settings.smtp_host),
        "has_smtp_from_email": bool(settings.smtp_from_email),
        "from_email": settings.from_email,
    }


@app.get("/admin/push/status", response_model=PushStatusOut)
def get_push_status(db: Session = Depends(get_db), _: User = Depends(get_current_superuser)) -> dict:
    registered_devices = db.scalar(select(func.count()).select_from(PushDeviceToken)) or 0
    users_with_devices = (
        db.scalar(select(func.count(func.distinct(PushDeviceToken.user_id))).select_from(PushDeviceToken)) or 0
    )
    return {
        "enabled": settings.push_enabled,
        "project_id": settings.firebase_project_id,
        "registered_devices": registered_devices,
        "users_with_devices": users_with_devices,
        "threshold_percent": settings.push_alert_threshold_percent,
    }


@app.post("/admin/push/test", response_model=MessageResponse)
def send_test_push(
    payload: PushTestRequest,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_superuser),
) -> MessageResponse:
    devices = db.scalars(select(PushDeviceToken).where(PushDeviceToken.user_id == user.id)).all()
    if not devices:
        return MessageResponse(message="No registered push devices found for this admin account yet.")
    if not settings.push_enabled:
        return MessageResponse(message="Firebase push is not configured on the server yet.")

    title = payload.title or "Stockfolio NG push test"
    body = payload.body or "Push alerts are wired up. This is a test notification."
    delivered = 0
    invalid_devices: list[PushDeviceToken] = []
    for device in devices:
        try:
            send_push_message(
                settings,
                token=device.token,
                title=title,
                body=body,
                data={
                    "type": "test_push",
                    "route": "portfolio",
                    "symbol": (payload.symbol or "").strip().upper(),
                },
            )
        except PushDeliveryError as exc:
            logger.warning("Push test delivery failed for %s: %s", device.platform, exc)
            if "UNREGISTERED" in str(exc).upper() or "INVALID_ARGUMENT" in str(exc).upper():
                invalid_devices.append(device)
            continue
        delivered += 1

    for device in invalid_devices:
        db.delete(device)
    if invalid_devices:
        db.commit()

    return MessageResponse(message=f"Sent test push to {delivered} device(s).")


@app.get("/admin/account-deletion-requests", response_model=list[AccountDeletionRequestOut])
def get_account_deletion_requests(
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    _: User = Depends(get_current_superuser),
) -> list[AccountDeletionRequest]:
    return db.scalars(
        select(AccountDeletionRequest)
        .order_by(desc(AccountDeletionRequest.created_at), desc(AccountDeletionRequest.id))
        .limit(limit)
    ).all()


@app.get("/portfolio/holdings", response_model=list[HoldingOut])
def list_holdings(db: Session = Depends(get_db), user: User = Depends(get_current_user)) -> list[dict]:
    holdings = db.scalars(
        select(PortfolioHolding)
        .options(selectinload(PortfolioHolding.stock))
        .where(PortfolioHolding.user_id == user.id)
        .order_by(PortfolioHolding.stock_symbol)
    ).all()
    return [holding_to_dict(holding) for holding in holdings]


@app.post("/portfolio/holdings", response_model=HoldingOut)
def save_holding(
    payload: HoldingUpsert,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    holding = upsert_holding(db, user, payload)
    return holding_to_dict(holding)


@app.delete("/portfolio/holdings/{symbol}", status_code=status.HTTP_204_NO_CONTENT)
def remove_holding(symbol: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)) -> None:
    deleted = delete_holding(db, user, symbol)
    if not deleted:
        raise HTTPException(status_code=404, detail="Holding not found")
