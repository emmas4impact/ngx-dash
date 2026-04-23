from datetime import date, datetime
import re
from typing import Any

import requests

from .settings import get_settings


class NgxFetchError(Exception):
    pass


CHART_ID_PATTERN = re.compile(r"stockchartdata/([A-Z0-9]+)")


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
    last_price = _number(_first(raw, ["Value", "last_price", "lastPrice", "price", "currentPrice", "close", "Close"]))
    previous_close = _number(_first(raw, ["previous_close", "previousClose", "pclose", "prevClose"]))
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

    return {
        "symbol": symbol_text,
        "name": _first(raw, ["SYMBOL2", "Name", "TickerName", "name", "companyName", "company", "security", "Security"]),
        "ticker_id": _first(raw, ["Id", "ticker_id", "tickerId", "id", "Ticker ID"]),
        "ngx_id": ngx_id,
        "sector": _first(raw, ["Sector", "sector"]),
        "last_price": last_price,
        "previous_close": previous_close,
        "open_price": _number(_first(raw, ["Open", "open", "open_price"])),
        "high_price": high_price,
        "low_price": low_price,
        "volume": _number(_first(raw, ["Volume", "volume"])),
        "market_cap": _number(_first(raw, ["MarketCap", "market_cap", "marketCap", "Mkt Cap"])),
        "change": _number(_first(raw, ["Change", "change"])),
        "percent_change": _number(
            _first(raw, ["PercChange", "percent_change", "changePercent", "percentageChange", "Change %"])
        ),
        "margin": margin,
        "source": source,
    }


def fetch_all_stocks_from_ngx() -> list[dict[str, Any]]:
    settings = get_settings()
    try:
        response = requests.get(
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


def fetch_historical_prices(ngx_id: str) -> list[dict[str, Any]]:
    if not ngx_id:
        return []

    try:
        response = requests.get(f"{get_settings().ngx_chart_base_url}{ngx_id}", timeout=20)
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
                "close_price": close_price,
            }
        )
        previous_close = close_price
    return rows


def discover_stock_ngx_id(symbol: str) -> str | None:
    symbol = symbol.strip().upper()
    if not symbol:
        return None

    settings = get_settings()
    try:
        response = requests.get(
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

    match = CHART_ID_PATTERN.search(response.text)
    return match.group(1) if match else None


def fetch_market_status_from_ngx() -> tuple[str, Any]:
    try:
        response = requests.get(get_settings().market_status_url, headers={"Accept": "application/json"}, timeout=10)
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
    try:
        response = requests.get(
            get_settings().market_snapshot_url,
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
        response = requests.get(
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
