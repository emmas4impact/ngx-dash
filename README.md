# NGX Portfolio Dashboard (ngx-dash)

An interactive Streamlit dashboard for tracking a Nigerian Exchange (NGX) equity portfolio. It pulls live holdings from Google Sheets, shows portfolio totals and per-symbol metrics with color-coded gains/losses, fetches current market status from NGX, and renders historical price charts for selected tickers. Auto-refresh runs only during trading hours on business days.

## Features
- Live portfolio table from Google Sheets with currency formatting and P/L coloring
- Aggregates: total portfolio value, invested amount, and total profit/loss
- Market status banner via NGX statistics endpoint
- Historical charts (line/bar) per stock using NGX chart data API
- Smart auto-refresh within configured market hours and timezone
- Server-side caching with manual “Refresh Data Cache & Rerun” button

## Demo Screenshot
> Run locally to view. Add your Google Sheet and NGX IDs (see Setup).

## Project Structure
- `main_dashboard.py` — Streamlit UI, layout, charts, metrics, and refresh logic
- `data_loader.py` — Google Sheets fetch, market status and historical price loaders (cached)
- `refresh_utils.py` — Auto-refresh conditions based on time, weekday, and market status
- `config.py` — App configuration: sheet names, NGX IDs, refresh windows, display columns, currency
- `requirements.txt` — Python dependencies

## Requirements
- Python 3.9+
- A Google Cloud service account JSON credential with Drive/Sheets access
- A Google Sheet with your portfolio data (see Columns)

## Quick Start
1) Install dependencies
```bash
pip install -r requirements.txt
```

2) Configure Google Sheets credentials (pick one):
- Local file: place your service account JSON in the repo root and set its name in `config.py` (`CREDS_FILE`).
- Streamlit Cloud: add the JSON to Streamlit Secrets under `gcp_service_account` (see “Deploy to Streamlit Cloud”).

3) Configure the app in `config.py`:
- `SPREADSHEET_NAME`, `WORKSHEET_NAME`
- `STOCK_ID_MAPPING` for symbols you want historical charts for
- `CURRENCY_SYMBOL`, `COLS_TO_DISPLAY`
- Timezone and market window: `GMT_OFFSET_FOR_REFRESH`, `MARKET_OPEN_HOUR`, `MARKET_CLOSE_HOUR`

4) Share the Google Sheet with your service account’s email.

5) Run the app
```bash
streamlit run main_dashboard.py
```

## Google Sheet Columns
Make sure your worksheet contains the following columns used by the app:
- Symbol
- Quantity
- Current Value
- Total Value (computed if not present)
- Avg. Purchase Price
- Total Cost
- Profit/Loss
- P/L % (accepts values like `12.3` or `0.123`; loader normalizes)
- Percent Change
- Last Updated
- Ticker ID (string)

Notes:
- The loader normalizes `P/L %` accepting either fractional (0–1) or percent (e.g., 12.3) inputs.
- `Total Value` will be computed as `Quantity * Current Value` if missing.

## NGX Historical Charts
Historical prices use NGX’s chart data endpoint. Map your sheet’s `Symbol` to NGX IDs in `config.py`:
```python
STOCK_ID_MAPPING = {
	"NB": "NGNB00000005",
	"ACCESSCORP": "NGACCESS0005",
	"ZENITHBANK": "NGZENITHBNK9",
	# ... add your symbols here
}
```
Only symbols present in `STOCK_ID_MAPPING` will appear in the chart dropdown.

## Auto-Refresh Behavior
- Controlled by `refresh_utils.check_auto_refresh_conditions()`
- Refresh triggers only on weekdays, during `MARKET_OPEN_HOUR`–`MARKET_CLOSE_HOUR` in `GMT_OFFSET_FOR_REFRESH`
- If NGX market status contains any of `MARKET_CLOSED_KEYWORDS`, auto-refresh is disabled
- Manual cache clear is available via the “Refresh Data Cache & Rerun Script” button

## Configuration Reference (config.py)
- `SPREADSHEET_NAME`, `WORKSHEET_NAME`: Source worksheet for portfolio data
- `CREDS_FILE`, `SCOPE`: Google service account auth
- `HISTORICAL_DATA_BASE_URL`, `MARKET_STATUS_URL`: NGX public endpoints
- `STOCK_ID_MAPPING`: Map your `Symbol` to NGX-specific chart IDs
- `REFRESH_INTERVAL_SECONDS`: Auto-refresh cadence when active (default 15 min)
- `GMT_OFFSET_FOR_REFRESH`, `MARKET_OPEN_HOUR`, `MARKET_CLOSE_HOUR`, `MARKET_CLOSED_KEYWORDS`
- `COLS_TO_DISPLAY`: Controls table columns and order
- `DATA_CACHE_TTL`, `MARKET_STATUS_CACHE_TTL`, `HISTORICAL_DATA_CACHE_TTL`: Caching TTLs
- `CURRENCY_SYMBOL`: e.g., `₦`

## Deploy to Streamlit Cloud
1) Push this repo to GitHub.
2) Create an app in Streamlit Cloud targeting `main_dashboard.py`.
3) In “Secrets”, add your service account credentials under the key `gcp_service_account` (JSON object). Example:
```toml
# .streamlit/secrets.toml (for local) or Streamlit Cloud Secrets UI
[gcp_service_account]
type = "service_account"
project_id = "your-project"
private_key_id = "..."
private_key = "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
client_email = "svc-account@your-project.iam.gserviceaccount.com"
client_id = "..."
auth_uri = "https://accounts.google.com/o/oauth2/auth"
token_uri = "https://oauth2.googleapis.com/token"
auth_provider_x509_cert_url = "https://www.googleapis.com/oauth2/v1/certs"
client_x509_cert_url = "..."
```
4) Set environment configs by editing `config.py` in the repo (or fork with your values).

## Troubleshooting
- “Credentials file missing” — place the JSON file and update `CREDS_FILE`, or use Streamlit Secrets.
- “Spreadsheet/Worksheet not found” — check names in `config.py` and sharing with the service account.
- No symbols in chart dropdown — add your symbol and NGX ID to `STOCK_ID_MAPPING`.
- P/L % looks off — ensure the sheet values are either fractions (0.12) or percents (12); the loader normalizes.
- Market status “Unknown” — NGX status endpoint may be unavailable; the app still runs.

## Development
Install dev dependencies and run Streamlit. Core modules are small and easy to extend. Useful entry points:
- Portfolio table rendering and metrics: `main_dashboard.py`
- Data ingestion and caching: `data_loader.py`
- Auto-refresh rules: `refresh_utils.py`

## License
Add a license if you plan to distribute. Credentials should never be committed.

