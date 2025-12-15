
import streamlit as st
import pandas as pd
import gspread
from oauth2client.service_account import ServiceAccountCredentials
import requests

from config import (
    SPREADSHEET_NAME, WORKSHEET_NAME, CREDS_FILE, SCOPE,
    HISTORICAL_DATA_BASE_URL, MARKET_STATUS_URL,
    DATA_CACHE_TTL, MARKET_STATUS_CACHE_TTL, HISTORICAL_DATA_CACHE_TTL
)



def format_pl_with_arrow_for_dataframe(val):

    if pd.isna(val) or not isinstance(val, (int, float)):
        return 'N/A'
    arrow = "⬆️ " if val > 0 else "⬇️ " if val < 0 else "➡️ "  # Or just "" for zero
    return f"{arrow}{val:,.2f}%"


@st.cache_data(ttl=DATA_CACHE_TTL)
def load_live_data_from_gsheet():
    try:

        creds = None
        if hasattr(st, 'secrets') and "gcp_service_account" in st.secrets:
            creds_dict = {}
            for key, val in st.secrets.gcp_service_account.items():
                creds_dict[key] = val
            creds = ServiceAccountCredentials.from_json_keyfile_dict(creds_dict, SCOPE)
        else:

            from config import CREDS_FILE
            creds = ServiceAccountCredentials.from_json_keyfile_name(CREDS_FILE, SCOPE)

        if not creds:
            st.error("Failed to load Google Sheets credentials.")
            return pd.DataFrame()
        client = gspread.authorize(creds)
        spreadsheet = client.open(SPREADSHEET_NAME)
        worksheet = spreadsheet.worksheet(WORKSHEET_NAME)
        data = worksheet.get_all_records(value_render_option='FORMATTED_VALUE')

        # data = worksheet.get_all_records(value_render_option='UNFORMATTED_VALUE')

        if not data:
            st.warning(f"No data from worksheet '{WORKSHEET_NAME}'. Check Apps Script.")
            return pd.DataFrame()

        df = pd.DataFrame(data)

        if 'P/L %' in df.columns:
            s = df['P/L %']

            # Handle formatted strings like "12.34%"
            if s.dtype == object:
                s = s.astype(str).str.replace('%', '', regex=False).str.strip()

            s = pd.to_numeric(s, errors='coerce')

            # If values are fractions (e.g. 0.1234), convert to percent
            non_na = s.dropna()
            if len(non_na) and non_na.abs().max() <= 1:
                s = s * 100.0

            df['P/L %'] = s

        # if 'P/L %' in df.columns:
        #     df['P/L %'] = pd.to_numeric(df['P/L %'], errors='coerce')
        #     if pd.api.types.is_numeric_dtype(df['P/L %']):
        #         df['P/L %'] = df['P/L %'] * 100.0
        #     else:
        #         st.warning("P/L % column could not be fully converted to a numeric type for scaling.")

        numeric_cols = [
            'Current Value', 'Percent Change', 'Quantity',
            'Avg. Purchase Price', 'Total Cost', 'Profit/Loss', 'P/L %'
        ]
        if 'Ticker ID' in df.columns:
            df['Ticker ID'] = df['Ticker ID'].astype(str)

        for col in numeric_cols:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors='coerce')

        if 'Quantity' in df.columns and 'Current Value' in df.columns and \
                pd.api.types.is_numeric_dtype(df['Quantity']) and pd.api.types.is_numeric_dtype(df['Current Value']):
            df['Total Value'] = df['Quantity'] * df['Current Value']
        else:
            df['Total Value'] = pd.NA

        if 'Last Updated' in df.columns:
            try:
                df['Last Updated'] = pd.to_datetime(df['Last Updated'], errors='coerce')
            except Exception:
                pass

        if 'P/L %' in df.columns and pd.api.types.is_numeric_dtype(df['P/L %']):
            df['P/L % Visual'] = df['P/L %'].apply(format_pl_with_arrow_for_dataframe)
        else:
            df['P/L % Visual'] = "N/A"
            # Add a debug message if P/L % wasn't suitable for visual formatting
            if 'P/L %' not in df.columns:
                st.warning("P/L % column missing, cannot create P/L % Visual.")
            elif not pd.api.types.is_numeric_dtype(df['P/L %']):
                st.warning(f"P/L % column is not numeric (type: {df['P/L %'].dtype}), P/L % Visual set to N/A.")

        return df


    except FileNotFoundError:
        st.error(f"Credentials file '{CREDS_FILE}' missing.")
        return pd.DataFrame()
    except gspread.exceptions.SpreadsheetNotFound:
        st.error(f"Spreadsheet '{SPREADSHEET_NAME}' not found.")
        return pd.DataFrame()
    except gspread.exceptions.WorksheetNotFound:
        st.error(f"Worksheet '{WORKSHEET_NAME}' not found.")
        return pd.DataFrame()
    except Exception as e:
        st.error(f"Error in load_live_data_from_gsheet: {e}")
        return pd.DataFrame()



@st.cache_data(ttl=HISTORICAL_DATA_CACHE_TTL)
def fetch_historical_data(stock_ngx_id):
    if not stock_ngx_id: return pd.DataFrame()
    try:
        response = requests.get(f"{HISTORICAL_DATA_BASE_URL}{stock_ngx_id}", timeout=10)
        response.raise_for_status();
        data = response.json()
        if not data: return pd.DataFrame()
        df_historical = pd.DataFrame(data, columns=['Timestamp', 'Price'])
        df_historical['Date'] = pd.to_datetime(df_historical['Timestamp'] / 1000, unit='s')
        return df_historical[['Date', 'Price']].sort_values(by='Date')
    except Exception as e:
        st.error(f"API/Processing Error (Historical for {stock_ngx_id}): {e}"); return pd.DataFrame()


@st.cache_data(ttl=MARKET_STATUS_CACHE_TTL)
def fetch_market_status():
    try:
        response = requests.get(MARKET_STATUS_URL, timeout=5);
        response.raise_for_status();
        status_data = response.json()
        if status_data and isinstance(status_data, list) and len(status_data) > 0 and "MktStatus1" in status_data[0]:
            return status_data[0]["MktStatus1"]
        return "Unknown"
    except Exception:
        return "Status API/Parse Error"