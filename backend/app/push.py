import base64
import json
import logging
from datetime import datetime, timezone

import requests
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2 import service_account
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from .models import PortfolioAlertState, PortfolioHolding, PushDeviceToken, User
from .settings import Settings


logger = logging.getLogger("ngx_dash")
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
                "notification": {
                    "click_action": "FLUTTER_NOTIFICATION_CLICK",
                },
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


def dispatch_portfolio_price_alerts(db: Session, settings: Settings) -> dict[str, int]:
    threshold = max(0.1, settings.push_alert_threshold_percent)
    devices = db.scalars(
        select(PushDeviceToken).where(PushDeviceToken.notifications_enabled.is_(True))
    ).all()
    tokens_by_user: dict[int, list[PushDeviceToken]] = {}
    for device in devices:
        tokens_by_user.setdefault(device.user_id, []).append(device)

    holdings = db.scalars(
        select(PortfolioHolding)
        .options(selectinload(PortfolioHolding.stock), selectinload(PortfolioHolding.user))
        .order_by(PortfolioHolding.user_id, PortfolioHolding.stock_symbol)
    ).all()

    alerts_sent = 0
    tokens_sent = 0
    for holding in holdings:
        current_price = float(holding.stock.last_price) if holding.stock and holding.stock.last_price is not None else None
        if current_price is None or current_price <= 0:
            continue

        state = db.scalar(
            select(PortfolioAlertState).where(
                PortfolioAlertState.user_id == holding.user_id,
                PortfolioAlertState.stock_symbol == holding.stock_symbol,
            )
        )
        if state is None:
            state = PortfolioAlertState(
                user_id=holding.user_id,
                stock_symbol=holding.stock_symbol,
                baseline_price=current_price,
                last_seen_price=current_price,
            )
            db.add(state)
            continue

        if state.baseline_price is None or float(state.baseline_price) <= 0:
            state.baseline_price = current_price
        reference_price = float(state.last_alert_price or state.baseline_price or state.last_seen_price or 0)
        state.last_seen_price = current_price
        if reference_price <= 0:
            continue

        change_percent = ((current_price - reference_price) / reference_price) * 100
        if abs(change_percent) < threshold:
            continue

        devices_for_user = tokens_by_user.get(holding.user_id, [])
        if not devices_for_user:
            continue

        title = (
            f"{holding.stock_symbol} is on fire today"
            if change_percent > 0
            else f"{holding.stock_symbol} is under pressure today"
        )
        body = (
            f"Current price NGN {current_price:,.2f} ({change_percent:+.2f}% since the last alert). "
            "Tap to view your portfolio."
        )
        invalid_devices: list[PushDeviceToken] = []
        delivered = 0
        for device in devices_for_user:
            try:
                send_push_message(
                    settings,
                    token=device.token,
                    title=title,
                    body=body,
                    data={
                        "type": "portfolio_price_alert",
                        "route": "portfolio",
                        "symbol": holding.stock_symbol,
                        "price": f"{current_price:.4f}",
                        "change_percent": f"{change_percent:.4f}",
                    },
                )
            except PushDeliveryError as exc:
                logger.warning("Push delivery failed for %s on %s: %s", holding.stock_symbol, device.platform, exc)
                if is_invalid_push_token_error(str(exc)):
                    invalid_devices.append(device)
                continue
            delivered += 1

        for device in invalid_devices:
            db.delete(device)

        if delivered:
            state.last_alert_price = current_price
            state.last_alert_change_percent = change_percent
            state.last_notified_at = datetime.now(timezone.utc)
            alerts_sent += 1
            tokens_sent += delivered

    db.commit()
    return {"alerts_sent": alerts_sent, "tokens_sent": tokens_sent}
