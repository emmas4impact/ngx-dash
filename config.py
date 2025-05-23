
SCOPE = ["https://spreadsheets.google.com/feeds", 'https://www.googleapis.com/auth/spreadsheets',
         "https://www.googleapis.com/auth/drive.file", "https://www.googleapis.com/auth/drive"]
CREDS_FILE = 'ngx-stock-6790b26a4e52.json'
SPREADSHEET_NAME = "shares"
WORKSHEET_NAME = "LiveStockData"

# For NGX API
HISTORICAL_DATA_BASE_URL = "https://doclib.ngxgroup.com/REST/api/stockchartdata/"
MARKET_STATUS_URL = "https://doclib.ngxgroup.com/REST/api/statistics/mktstatus"

# Stock ID Mapping for Historical Charts
STOCK_ID_MAPPING = {
    "NB": "NGNB00000005", "ACCESSCORP": "NGACCESS0005", "ZENITHBANK": "NGZENITHBNK9",
    "GTCO": "NGGTCO000002", "FIDELITYBK": "NGFIDELITYB5", "FIRSTHOLDCO": "NGFBNH000009",
    "GUINEAINS": "NGGUINEAINS0", "HONYFLOUR": "NGHONYFLOUR7", "MTNN": "NGMTNN000002",
    "NSLTECH": "NGNSLTECH006", "TRANSCORP": "NGTRANSCORP7", "UNITYBNK": "NGUNITYBANK3",
}

# Auto-Refresh Configuration
REFRESH_INTERVAL_SECONDS = 2 * 60  # 10 minutes
GMT_OFFSET_FOR_REFRESH = 1 # For GMT+1
MARKET_OPEN_HOUR = 8    # 9 AM
MARKET_CLOSE_HOUR = 18  # 6 PM (refresh stops at 18:00)
MARKET_CLOSED_KEYWORDS = ["ENDOFDAY", "CLOSED", "MARKET_CLOSED", "PREOPEN", "PRE_OPEN"]

COLS_TO_DISPLAY = [
    'Symbol', 'Quantity', 'Current Value', 'Total Value',
    'Avg. Purchase Price', 'Total Cost',
    'Profit/Loss', 'P/L %',
    'Percent Change',
    'Last Updated', 'Ticker ID'
]

# Cache TTLs (Time-To-Live in seconds)
DATA_CACHE_TTL = 300  # 5 minutes for main data
MARKET_STATUS_CACHE_TTL = 60 # 1 minute for market status
HISTORICAL_DATA_CACHE_TTL = 300 # 5 minutes for historical data

# Currency symbol
CURRENCY_SYMBOL = "₦"