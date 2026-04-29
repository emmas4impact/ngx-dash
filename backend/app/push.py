import base64
import json
import logging
from datetime import date, datetime, timezone

import requests
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2 import service_account
from sqlalchemy import desc, select
from sqlalchemy.orm import Session

from .models import MarketStatus, PushDeviceToken, Stock, SyncLog, User
from .settings import Settings


logger = logging.getLogger("stockfoliong")
FCM_SCOPES = ["https://www.googleapis.com/auth/firebase.messaging"]


class PushDeliveryError(RuntimeError):
    pass


def _load_service_account_info(settings: Settings) -> dict:
    if settings.firebase_service_account_json:
        raw = settings.firebase_service_account_json.strip()
        if raw.startswith("{"):
            return json.loads(raw)
        try:
            decoded = base64.b64decode(raw).decode("utf-8")
            return json.loads(decoded)
        except Exception as exc:  # noqa: BLE001
            raise PushDeliveryError("FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON or base64-encoded JSON.") from exc

    if settings.firebase_service_account_file:
        with open(settings.firebase_service_account_file, encoding="utf-8") as handle:
            return json.load(handle)

    raise PushDeliveryError("Firebase service account credentials are not configured.")


def _fcm_access_token(settings: Settings) -> tuple[str, str]:
    if not settings.push_enabled:
        raise PushDeliveryError("Firebase push is not configured on the server.")

    service_account_info = _load_service_account_info(settings)
    project_id = settings.firebase_project_id or service_account_info.get("project_id")
    if not project_id:
        raise PushDeliveryError("Firebase project ID is missing.")

    credentials = service_account.Credentials.from_service_account_info(
        service_account_info,
        scopes=FCM_SCOPES,
    )
    credentials.refresh(GoogleAuthRequest())
    if not credentials.token:
        raise PushDeliveryError("Could not obtain an OAuth access token for Firebase Cloud Messaging.")

    return credentials.token, project_id


def send_push_message(
    settings: Settings,
    *,
    token: str,
    title: str,
    body: str,
    data: dict[str, str] | None = None,
) -> dict:
    access_token, project_id = _fcm_access_token(settings)
    payload = {
        "message": {
            "token": token,
            "notification": {
                "title": title,
                "body": body,
            },
            "data": data or {},
            "android": {
                "priority": "high",
            },
            "apns": {
                "headers": {
                    "apns-priority": "10",
                },
                "payload": {
                    "aps": {
                        "sound": "default",
                    }
                },
            },
        }
    }
    response = requests.post(
        f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send",
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json; charset=utf-8",
        },
        json=payload,
        timeout=20,
    )
    if response.status_code >= 400:
        raise PushDeliveryError(_fcm_error_message(response))
    return response.json() if response.content else {}


def _fcm_error_message(response: requests.Response) -> str:
    try:
        payload = response.json()
    except ValueError:
        return f"FCM error {response.status_code}: {response.text}"

    error = payload.get("error") if isinstance(payload, dict) else None
    if isinstance(error, dict):
        status = error.get("status")
        message = error.get("message")
        details = error.get("details") or []
        detail_status = ""
        if details and isinstance(details, list):
            first_detail = details[0]
            if isinstance(first_detail, dict):
                detail_status = first_detail.get("errorCode") or ""
        descriptor = detail_status or status or response.status_code
        return f"FCM error {descriptor}: {message or response.text}"
    return f"FCM error {response.status_code}: {response.text}"


def is_invalid_push_token_error(message: str) -> bool:
    normalized = message.upper()
    return "UNREGISTERED" in normalized or "INVALID_ARGUMENT" in normalized


def upsert_push_token(
    db: Session,
    user: User,
    *,
    token: str,
    platform: str,
    device_label: str | None = None,
) -> PushDeviceToken:
    normalized_token = token.strip()
    record = db.scalar(select(PushDeviceToken).where(PushDeviceToken.token == normalized_token))
    if record is None:
        record = PushDeviceToken(token=normalized_token)
        db.add(record)

    record.user_id = user.id
    record.platform = platform.strip().lower()
    record.device_label = device_label.strip() if device_label else None
    record.notifications_enabled = True
    record.last_registered_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(record)
    return record


def remove_push_token(db: Session, user: User, *, token: str) -> bool:
    record = db.scalar(
        select(PushDeviceToken).where(
            PushDeviceToken.user_id == user.id,
            PushDeviceToken.token == token.strip(),
        )
    )
    if record is None:
        return False
    db.delete(record)
    db.commit()
    return True


def _normalized_market_status(status: str | None) -> str:
    return (status or "").strip().upper().replace("-", "_")


def _is_market_open_status(status: str | None) -> bool:
    normalized = _normalized_market_status(status)
    if not normalized:
        return False
    if "PRE_OPEN" in normalized or "END_OF_DAY" in normalized or "ENDOFDAY" in normalized:
        return False
    return "START_INDEX" in normalized or "OPEN" in normalized


def _sync_log_exists(db: Session, source: str) -> bool:
    return db.scalar(select(SyncLog.id).where(SyncLog.source == source).limit(1)) is not None


def _record_push_log(db: Session, source: str, message: str | None = None) -> None:
    db.add(SyncLog(status="success", source=source, message=message))


def _deliver_push_bundle(
    db: Session,
    settings: Settings,
    devices: list[PushDeviceToken],
    *,
    title: str,
    body: str,
    data: dict[str, str],
) -> int:
    invalid_devices: list[PushDeviceToken] = []
    delivered = 0
    for device in devices:
        try:
            send_push_message(
                settings,
                token=device.token,
                title=title,
                body=body,
                data=data,
            )
        except PushDeliveryError as exc:
            logger.warning("Push delivery failed on %s for %s: %s", device.platform, data.get("symbol", "market"), exc)
            if is_invalid_push_token_error(str(exc)):
                invalid_devices.append(device)
            continue
        delivered += 1

    for device in invalid_devices:
        db.delete(device)

    return delivered


def dispatch_market_price_alerts(db: Session, settings: Settings) -> dict[str, int]:
    threshold = max(0.1, settings.push_alert_threshold_percent)
    devices = db.scalars(
        select(PushDeviceToken).where(PushDeviceToken.notifications_enabled.is_(True))
    ).all()
    if not devices:
        return {"market_open_alerts_sent": 0, "stock_alerts_sent": 0, "tokens_sent": 0}

    market_open_alerts_sent = 0
    stock_alerts_sent = 0
    tokens_sent = 0

    today = date.today().isoformat()
    market_status = db.scalar(select(MarketStatus).order_by(MarketStatus.updated_at.desc(), MarketStatus.id.desc()).limit(1))
    if market_status is not None and _is_market_open_status(market_status.status):
        source = f"market_open_push:{today}"
        if not _sync_log_exists(db, source):
            delivered = _deliver_push_bundle(
                db,
                settings,
                devices,
                title="NGX market is now open",
                body="The trading session is live. Open Stockfolio NG to track current prices and daily charts.",
                data={
                    "type": "market_open_alert",
                    "route": "home",
                    "status": market_status.status,
                },
            )
            if delivered:
                _record_push_log(db, source, f"Delivered market-open alert to {delivered} device(s).")
                market_open_alerts_sent = 1
                tokens_sent += delivered

    movers = db.scalars(
        select(Stock)
        .where(Stock.last_price.is_not(None), Stock.percent_change.is_not(None))
        .order_by(desc(Stock.percent_change), Stock.symbol)
    ).all()
    for stock in movers:
        change_percent = float(stock.percent_change or 0)
        current_price = float(stock.last_price or 0)
        if current_price <= 0 or abs(change_percent) < threshold:
            continue

        source = f"market_stock_push:{today}:{stock.symbol}"
        if _sync_log_exists(db, source):
            continue

        title = (
            f"{stock.symbol} is on fire today"
            if change_percent > 0
            else f"{stock.symbol} is under pressure today"
        )
        body = (
            f"Current price NGN {current_price:,.2f} ({change_percent:+.2f}% today). "
            "Tap to inspect the stock chart."
        )
        delivered = _deliver_push_bundle(
            db,
            settings,
            devices,
            title=title,
            body=body,
            data={
                "type": "market_price_alert",
                "route": "stocks",
                "symbol": stock.symbol,
                "price": f"{current_price:.4f}",
                "change_percent": f"{change_percent:.4f}",
            },
        )
        if delivered:
            _record_push_log(db, source, f"Delivered {stock.symbol} market alert to {delivered} device(s).")
            stock_alerts_sent += 1
            tokens_sent += delivered

    db.commit()
    return {
        "market_open_alerts_sent": market_open_alerts_sent,
        "stock_alerts_sent": stock_alerts_sent,
        "tokens_sent": tokens_sent,
    }
