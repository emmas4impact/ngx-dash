from datetime import date, datetime, timedelta
from functools import lru_cache
from html import unescape
import re
from threading import Lock
import time
from typing import Any
from urllib.parse import urlparse

import requests

from .settings import get_settings


class NgxFetchError(Exception):
    pass


CHART_ID_PATTERN = re.compile(r"stockchartdata/([A-Z0-9]+)")
WEBSITE_PATTERN = re.compile(
    r"Website:\s*</td>\s*<td[^>]*>.*?<a\s+href=\"([^\"]+)\"",
    re.IGNORECASE | re.DOTALL,
)

_session: requests.Session | None = None
_session_lock = Lock()
_ttl_cache_store: dict[tuple[Any, ...], tuple[float, Any]] = {}
_ttl_cache_lock = Lock()


def _get_session() -> requests.Session:
    global _session
    if _session is not None:
        return _session
    with _session_lock:
        if _session is None:
            _session = requests.Session()
    return _session


def _ttl_cache(ttl_seconds: int):
    def decorator(func):
        def wrapper(*args, **kwargs):
            key = (func.__name__, args, tuple(sorted(kwargs.items())))
            now = time.monotonic()
            with _ttl_cache_lock:
                cached = _ttl_cache_store.get(key)
                if cached is not None:
                    expires_at, value = cached
                    if expires_at > now:
                        return value
                    _ttl_cache_store.pop(key, None)
            value = func(*args, **kwargs)
            with _ttl_cache_lock:
                _ttl_cache_store[key] = (now + ttl_seconds, value)
            return value

        return wrapper

    return decorator


def _number(value: Any) -> float | None:
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        return float(value)
    cleaned = str(value).replace(",", "").replace("%", "").replace("(", "-").replace(")", "").strip()
    try:
        return float(cleaned)
    except ValueError:
        return None


def _ngxpulse_headers() -> dict[str, str]:
    settings = get_settings()
    api_key = (settings.ngxpulse_api_key or "").strip()
    if not api_key:
        raise NgxFetchError("NGX Pulse API key is not configured.")
    return {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-API-Key": api_key,
    }


def _first(item: dict[str, Any], keys: list[str]) -> Any:
    lowered = {str(key).lower(): value for key, value in item.items()}
    for key in keys:
        if key in item:
            return item[key]
        if key.lower() in lowered:
            return lowered[key.lower()]
    return None


def normalize_stock(raw: dict[str, Any], source: str) -> dict[str, Any] | None:
    symbol = _first(raw, ["SYMBOL", "symbol", "ticker", "code", "Symbol", "Ticker"])
    if not symbol:
        return None

    symbol_text = str(symbol).strip().upper()
    last_price = _number(
        _first(
            raw,
            [
                "Value",
                "last_price",
                "lastPrice",
                "price",
                "currentPrice",
                "current_price",
                "close",
                "Close",
            ],
        )
    )
    previous_close = _number(_first(raw, ["previous_close", "previousClose", "pclose", "prevClose"]))
    raw_price_move = _number(
        _first(raw, ["Change", "change", "PercChange", "percent_change", "changePercent", "percentageChange", "Change %"])
    )
    open_price = _number(_first(raw, ["Open", "open", "open_price"]))
    if previous_close in (None, 0) and last_price not in (None, 0) and raw_price_move is not None:
        previous_close = last_price / (1 + (raw_price_move / 100)) if raw_price_move != -100 else None
    if open_price in (None, 0) and last_price is not None and raw_price_move is not None:
        derived_open = last_price - raw_price_move
        if derived_open > 0:
            open_price = derived_open
    high_price = _number(_first(raw, ["High", "high", "high_price", "dayHigh"]))
    low_price = _number(_first(raw, ["Low", "low", "low_price", "dayLow"]))
    ngx_id = _first(raw, ["ngx_id", "ngxId", "isin", "ISIN"])
    if ngx_id is None:
        try:
            from config import STOCK_ID_MAPPING
        except Exception:
            STOCK_ID_MAPPING = {}
        ngx_id = STOCK_ID_MAPPING.get(symbol_text)

    margin = _number(_first(raw, ["margin", "spread", "Spread"]))
    if margin is None and high_price is not None and low_price is not None and last_price:
        margin = ((high_price - low_price) / last_price) * 100

    reference_price = previous_close if previous_close not in (None, 0) else open_price
    computed_change: float | None = None
    computed_percent_change: float | None = None
    if raw_price_move is not None and open_price not in (None, 0):
        computed_change = raw_price_move
        computed_percent_change = (computed_change / open_price) * 100
    elif last_price is not None and reference_price not in (None, 0):
        computed_change = last_price - reference_price
        computed_percent_change = (computed_change / reference_price) * 100

    return {
        "symbol": symbol_text,
        "name": _first(raw, ["SYMBOL2", "Name", "TickerName", "name", "companyName", "company", "security", "Security"]),
        "ticker_id": _first(raw, ["Id", "ticker_id", "tickerId", "id", "Ticker ID"]),
        "ngx_id": ngx_id,
        "sector": _first(raw, ["Sector", "sector"]),
        "last_price": last_price,
        "previous_close": previous_close,
        "open_price": open_price,
        "high_price": high_price,
        "low_price": low_price,
        "volume": _number(_first(raw, ["Volume", "volume"])),
        "market_cap": (
            _number(_first(raw, ["MarketCap", "market_cap", "marketCap", "Mkt Cap"]))
            or (
                (_number(_first(raw, ["shares_outstanding", "sharesOutstanding"])) or 0) * last_price
                if last_price is not None
                else None
            )
        ),
        "change": computed_change if computed_change is not None else raw_price_move,
        "percent_change": (
            computed_percent_change
            if computed_percent_change is not None
            else raw_price_move
        ),
        "margin": margin,
        "source": source,
    }


def fetch_all_stocks_from_ngx() -> list[dict[str, Any]]:
    settings = get_settings()
    if settings.ngxpulse_enabled:
        try:
            response = _get_session().get(
                f"{settings.ngxpulse_base_url}/api/ngxdata/stocks",
                headers=_ngxpulse_headers(),
                timeout=20,
            )
            response.raise_for_status()
            payload = response.json()
        except requests.RequestException as exc:
            raise NgxFetchError(f"NGX Pulse stocks request failed: {exc}") from exc
        except ValueError as exc:
            raise NgxFetchError(f"NGX Pulse stocks response was not valid JSON: {exc}") from exc
        if not isinstance(payload, list):
            raise NgxFetchError("NGX Pulse stocks response was not a list of equities.")
        return [
            stock
            for item in payload
            if isinstance(item, dict) and (stock := normalize_stock(item, "ngxpulse"))
        ]

    try:
        response = _get_session().get(
            settings.ngx_ticker_url,
            params={"$filter": "TickerType eq 'EQUITIES'", "page_size": "1000"},
            headers={"Accept": "application/json"},
            timeout=20,
        )
        response.raise_for_status()
        payload = response.json()
    except requests.RequestException as exc:
        raise NgxFetchError(f"NGX ticker request failed: {exc}") from exc
    except ValueError as exc:
        raise NgxFetchError(f"NGX ticker response was not valid JSON: {exc}") from exc
    if isinstance(payload, dict):
        payload = payload.get("data") or payload.get("stocks") or payload.get("results") or []
    if not isinstance(payload, list):
        raise NgxFetchError("NGX ticker response was not a list of equities.")

    return [stock for item in payload if isinstance(item, dict) and (stock := normalize_stock(item, "ngx_doclib"))]


@_ttl_cache(ttl_seconds=30)
def fetch_all_stocks_from_ngx_cached() -> list[dict[str, Any]]:
    return fetch_all_stocks_from_ngx()


def fetch_historical_prices(symbol: str, ngx_id: str | None = None) -> list[dict[str, Any]]:
    settings = get_settings()
    normalized_symbol = symbol.strip().upper()
    if settings.ngxpulse_enabled:
        today = date.today()
        from_date = today - timedelta(days=365 * 5)
        try:
            response = _get_session().get(
                f"{settings.ngxpulse_base_url}/api/ngxdata/prices/{normalized_symbol}",
                params={
                    "from": from_date.isoformat(),
                    "to": today.isoformat(),
                },
                headers=_ngxpulse_headers(),
                timeout=20,
            )
            response.raise_for_status()
            payload = response.json()
        except requests.RequestException as exc:
            raise NgxFetchError(f"NGX Pulse historical prices request failed for {normalized_symbol}: {exc}") from exc
        except ValueError as exc:
            raise NgxFetchError(f"NGX Pulse historical prices response was not valid JSON for {normalized_symbol}: {exc}") from exc

        prices = payload.get("prices") if isinstance(payload, dict) else None
        if not isinstance(prices, list):
            raise NgxFetchError(f"NGX Pulse historical prices response was not a prices list for {normalized_symbol}.")

        rows: list[dict[str, Any]] = []
        for item in prices:
            if not isinstance(item, dict):
                continue
            trade_date = item.get("trade_date")
            if not trade_date:
                continue
            try:
                parsed_date = date.fromisoformat(str(trade_date))
            except ValueError:
                continue
            rows.append(
                {
                    "trade_date": parsed_date,
                    "open_price": _number(item.get("open_price")) or _number(item.get("close_price")),
                    "high_price": _number(item.get("high_price")),
                    "low_price": _number(item.get("low_price")),
                    "close_price": _number(item.get("close_price")),
                    "volume": _number(item.get("volume")),
                }
            )
        return [row for row in rows if row.get("close_price") is not None]

    if not ngx_id:
        return []

    try:
        response = _get_session().get(f"{settings.ngx_chart_base_url}{ngx_id}", timeout=20)
        response.raise_for_status()
        payload = response.json()
    except requests.RequestException as exc:
        raise NgxFetchError(f"NGX chart request failed for {ngx_id}: {exc}") from exc
    except ValueError as exc:
        raise NgxFetchError(f"NGX chart response was not valid JSON for {ngx_id}: {exc}") from exc
    if not isinstance(payload, list):
        raise NgxFetchError(f"NGX chart response was not a list for {ngx_id}.")

    raw_rows: list[tuple[date, float]] = []
    for item in payload:
        if not isinstance(item, list) or len(item) < 2:
            continue
        timestamp_ms, price = item[0], _number(item[1])
        if price is None:
            continue
        raw_rows.append((datetime.fromtimestamp(float(timestamp_ms) / 1000).date(), price))

    rows: list[dict[str, Any]] = []
    previous_close: float | None = None
    for trade_date, close_price in sorted(raw_rows, key=lambda item: item[0]):
        rows.append(
            {
                "trade_date": trade_date,
                "open_price": previous_close if previous_close is not None else close_price,
                "high_price": close_price,
                "low_price": close_price,
                "close_price": close_price,
            }
        )
        previous_close = close_price
    return rows


def fetch_company_profile_html(symbol: str) -> str:
    symbol = symbol.strip().upper()
    if not symbol:
        return ""

    settings = get_settings()
    try:
        response = _get_session().get(
            settings.company_profile_url,
            params={
                "symbol": symbol,
                "directory": "companydirectory",
                "tdate": datetime.now().strftime("%Y-%m-%dT00:00:00"),
            },
            headers={
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
                "User-Agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"
                ),
            },
            timeout=15,
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        raise NgxFetchError(f"NGX company profile request failed for {symbol}: {exc}") from exc

    return response.text


@lru_cache(maxsize=512)
def discover_stock_ngx_id(symbol: str) -> str | None:
    html = fetch_company_profile_html(symbol)
    match = CHART_ID_PATTERN.search(html)
    return match.group(1) if match else None


@lru_cache(maxsize=512)
def discover_stock_website_domain(symbol: str) -> str | None:
    html = fetch_company_profile_html(symbol)
    match = WEBSITE_PATTERN.search(html)
    if not match:
        return None

    website = unescape(match.group(1)).strip()
    if not website:
        return None
    if not website.startswith(("http://", "https://")):
        website = f"https://{website}"

    parsed = urlparse(website)
    domain = parsed.netloc.lower().removeprefix("www.")
    return domain or None


@lru_cache(maxsize=512)
def fetch_stock_logo(symbol: str) -> tuple[bytes, str] | None:
    domain = discover_stock_website_domain(symbol)
    if not domain:
        return None

    try:
        response = _get_session().get(
            "https://www.google.com/s2/favicons",
            params={"domain": domain, "sz": "64"},
            headers={"Accept": "image/*"},
            timeout=10,
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        raise NgxFetchError(f"Company logo request failed for {symbol}: {exc}") from exc

    if not response.content:
        return None

    media_type = response.headers.get("Content-Type", "image/png").split(";")[0].strip()
    return response.content, media_type or "image/png"


def fetch_market_status_from_ngx() -> tuple[str, Any]:
    settings = get_settings()
    if settings.ngxpulse_enabled:
        try:
            response = _get_session().get(
                f"{settings.ngxpulse_base_url}/api/ngxdata/market-status",
                headers=_ngxpulse_headers(),
                timeout=10,
            )
            response.raise_for_status()
            payload = response.json()
        except requests.RequestException as exc:
            raise NgxFetchError(f"NGX Pulse market status request failed: {exc}") from exc
        except ValueError as exc:
            raise NgxFetchError(f"NGX Pulse market status response was not valid JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise NgxFetchError("NGX Pulse market status response was not an object.")
        raw_status = str(payload.get("status") or "unknown").strip().lower()
        status = "OPEN" if raw_status == "open" else "CLOSED"
        return status, payload

    try:
        response = _get_session().get(
            settings.market_status_url,
            headers={"Accept": "application/json"},
            timeout=10,
        )
        response.raise_for_status()
        payload = response.json()
    except requests.RequestException as exc:
        raise NgxFetchError(f"NGX market status request failed: {exc}") from exc
    except ValueError as exc:
        raise NgxFetchError(f"NGX market status response was not valid JSON: {exc}") from exc

    status = "UNKNOWN"
    if isinstance(payload, list) and payload:
        first = payload[0]
        if isinstance(first, dict):
            status = str(first.get("MktStatus1") or first.get("status") or first.get("Status") or status)
    elif isinstance(payload, dict):
        status = str(payload.get("MktStatus1") or payload.get("status") or payload.get("Status") or status)
    return status, payload


def fetch_market_snapshot_from_ngx() -> dict[str, Any]:
    settings = get_settings()
    if settings.ngxpulse_enabled:
        try:
            response = _get_session().get(
                f"{settings.ngxpulse_base_url}/api/ngxdata/market",
                headers=_ngxpulse_headers(),
                timeout=10,
            )
            response.raise_for_status()
            payload = response.json()
        except requests.RequestException as exc:
            raise NgxFetchError(f"NGX Pulse market overview request failed: {exc}") from exc
        except ValueError as exc:
            raise NgxFetchError(f"NGX Pulse market overview response was not valid JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise NgxFetchError("NGX Pulse market overview response was not an object.")

        return {
            "asi": _number(payload.get("asi")),
            "deals": _number(payload.get("deals")),
            "volume": _number(payload.get("volume")),
            "value": _number(payload.get("value")),
            "market_cap": _number(payload.get("market_cap")),
            "bond_cap": _number(payload.get("bond_cap")),
            "etf_cap": _number(payload.get("etf_cap")),
            "source": "ngxpulse_market",
        }

    try:
        response = _get_session().get(
            settings.market_snapshot_url,
            headers={
                "Accept": "application/json;odata=verbose",
                "Content-Type": "application/json;odata=verbose",
                "Origin": "https://ngxgroup.com",
                "Referer": "https://ngxgroup.com/exchange/data/company-profile/",
            },
            timeout=10,
        )
        response.raise_for_status()
        payload = response.json()
    except requests.RequestException as exc:
        raise NgxFetchError(f"NGX market snapshot request failed: {exc}") from exc
    except ValueError as exc:
        raise NgxFetchError(f"NGX market snapshot response was not valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise NgxFetchError("NGX market snapshot response was not an object.")

    return {
        "asi": _number(_first(payload, ["ASI"])),
        "deals": _number(_first(payload, ["DEALS"])),
        "volume": _number(_first(payload, ["VOLUME"])),
        "value": _number(_first(payload, ["VALUE"])),
        "market_cap": _number(_first(payload, ["CAP"])),
        "bond_cap": _number(_first(payload, ["BOND_CAP"])),
        "etf_cap": _number(_first(payload, ["ETF_CAP"])),
        "source": "ngx_market_snapshot",
    }


def fetch_company_news_from_ngx(ngx_id: str) -> list[dict[str, Any]]:
    if not ngx_id:
        return []

    settings = get_settings()
    params = {
        "$select": "URL,Modified,InternationSecIN,Type_of_Submission",
        "$orderby": "Modified desc",
        "$filter": (
            f"InternationSecIN eq '{ngx_id}' and "
            "(Type_of_Submission eq 'Corporate Actions' or "
            "Type_of_Submission eq 'Corporate Disclosures' or "
            "substringof('Meeting' ,Type_of_Submission))"
        ),
    }
    try:
        response = _get_session().get(
            settings.company_news_url,
            params=params,
            headers={"Accept": "application/json;odata=verbose"},
            timeout=15,
        )
        response.raise_for_status()
        payload = response.json()
    except requests.RequestException as exc:
        raise NgxFetchError(f"NGX company news request failed for {ngx_id}: {exc}") from exc
    except ValueError as exc:
        raise NgxFetchError(f"NGX company news response was not valid JSON for {ngx_id}: {exc}") from exc

    results: Any = payload
    if isinstance(payload, dict):
        results = payload.get("d", {}).get("results", [])
    if not isinstance(results, list):
        raise NgxFetchError(f"NGX company news response was not a list for {ngx_id}.")

    items: list[dict[str, Any]] = []
    for item in results:
        if not isinstance(item, dict):
            continue
        url_info = item.get("URL")
        if not isinstance(url_info, dict):
            url_info = {}
        items.append(
            {
                "title": url_info.get("Description"),
                "url": url_info.get("Url"),
                "modified": item.get("Modified"),
                "ngx_id": item.get("InternationSecIN") or ngx_id,
                "submission_type": item.get("Type_of_Submission"),
            }
        )
    return items


@_ttl_cache(ttl_seconds=60)
def fetch_market_snapshot_cached() -> dict[str, Any]:
    return fetch_market_snapshot_from_ngx()


@_ttl_cache(ttl_seconds=300)
def fetch_company_news_cached(ngx_id: str) -> list[dict[str, Any]]:
    return fetch_company_news_from_ngx(ngx_id)


@_ttl_cache(ttl_seconds=900)
def fetch_historical_prices_cached(
    symbol: str,
    ngx_id: str | None = None,
) -> list[dict[str, Any]]:
    return fetch_historical_prices(symbol, ngx_id)


def legacy_seed_stocks() -> list[dict[str, Any]]:
    try:
        from config import STOCK_ID_MAPPING
    except Exception:
        STOCK_ID_MAPPING = {}

    stocks = []
    for symbol, ngx_id in STOCK_ID_MAPPING.items():
        last_price = None
        try:
            history = fetch_historical_prices(ngx_id)
        except NgxFetchError:
            history = []
        if history:
            last_price = history[-1]["close_price"]
        stocks.append(
            {
                "symbol": symbol.upper(),
                "name": symbol.upper(),
                "ngx_id": ngx_id,
                "last_price": last_price,
                "source": "legacy_stock_mapping",
            }
        )
    return stocks
