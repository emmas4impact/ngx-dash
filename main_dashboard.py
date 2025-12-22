
import streamlit as st
import plotly.express as px
import pandas as pd
from streamlit_autorefresh import st_autorefresh
from datetime import datetime # <<< Ensure datetime is imported
import pytz

from config import (
    STOCK_ID_MAPPING, REFRESH_INTERVAL_SECONDS, COLS_TO_DISPLAY,GMT_OFFSET_FOR_REFRESH,
    CURRENCY_SYMBOL  # Assuming COLS_TO_DISPLAY will be adjusted
)

from data_loader import load_live_data_from_gsheet, fetch_historical_data, fetch_market_status

from refresh_utils import check_auto_refresh_conditions

st.set_page_config(layout="wide")
st.title("📈 NGX Portfolio Dashboard")

market_status = fetch_market_status()
st.subheader(f"Market Status: {market_status}")
st.sidebar.markdown("---")

try:

    target_tz_str_for_display = f'Etc/GMT-{GMT_OFFSET_FOR_REFRESH}'
    target_tz_for_display = pytz.timezone(target_tz_str_for_display)
    now_in_target_tz = datetime.now(target_tz_for_display)
    last_refreshed_display_text = f"Last data update: {now_in_target_tz.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    st.sidebar.caption(last_refreshed_display_text) # Display it in the sidebar
except Exception as e:
    st.sidebar.caption(f"Timezone info error: {e}")


should_refresh = check_auto_refresh_conditions(market_status)

if should_refresh:
    st_autorefresh(interval=REFRESH_INTERVAL_SECONDS * 1000, key="dashboard_autorefresh")
    st.sidebar.caption(f"Auto-refresh is ON (every {REFRESH_INTERVAL_SECONDS // 60} mins).")
else:
    st.sidebar.caption("Auto-refresh is OFF based on current conditions.")

st.markdown("---")

# st.sidebar.header("Stock ID Mapping for Charts")
# st.sidebar.info("Ensure `STOCK_ID_MAPPING` in `config file` is correct.")
# st.sidebar.json(STOCK_ID_MAPPING, expanded=False)

live_df = load_live_data_from_gsheet()


if not live_df.empty:
    st.header("Portfolio Snapshot")

    display_df = live_df.copy()

    if "Last Updated" in display_df.columns:
        s = display_df["Last Updated"]

        s = s.astype(str).str.replace("\u00a0", " ", regex=False).str.strip()

        s = s.replace({"None": "", "nan": "", "NaT": ""})

        # parse flexibly
        display_df["Last Updated"] = pd.to_datetime(s, errors="coerce")




    def pl_visual(val):
        try:
            v = float(val)
        except (TypeError, ValueError):
            return ""

        if v > 0:
            return f"▲ {v:.2f}%"
        elif v < 0:
            return f"▼ {abs(v):.2f}%"
        else:
            return "0.00%"


    if "P/L %" in display_df.columns:
        display_df["P/L %"] = display_df["P/L %"].apply(pl_visual)

    cols_to_display_updated = []
    for col in COLS_TO_DISPLAY:
        if col == "P/L %" and "P/L %" in display_df.columns:
            cols_to_display_updated.append("P/L %")
        elif col in display_df.columns:
            cols_to_display_updated.append(col)
    final_cols_to_display = cols_to_display_updated

    column_config = {
        "Current Value": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "Total Value": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "Avg. Purchase Price": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "Total Cost": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "Profit/Loss": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "P/L %":  st.column_config.TextColumn(label="P/L %"),
        "Percent Change": st.column_config.NumberColumn(format="%.2f"),
        "Quantity": st.column_config.NumberColumn(format="%d"),  # Integer format
        "Last Updated": st.column_config.DatetimeColumn(format="YYYY-MM-DD HH:mm:ss")
    }
    active_column_config = {k: v for k, v in column_config.items() if k in final_cols_to_display}


    def pl_style(val):
        try:
            v = float(val)
        except (TypeError, ValueError):
            return ""

        if v > 0:
            return "color: green; font-weight: 600;"
        elif v < 0:
            return "color: red; font-weight: 600;"
        else:
            return "color: gray;"


    def pl_visual_style(val):
        if isinstance(val, str):
            if val.startswith("▲"):
                return "color: green; font-weight: 600;"
            if val.startswith("▼"):
                return "color: red; font-weight: 600;"
        return "color: gray;"


    df_to_show = display_df[final_cols_to_display].copy()
    styled_df = df_to_show.style

    if "Profit/Loss" in df_to_show.columns:
        styled_df = styled_df.map(pl_style, subset=["Profit/Loss"])

    # Color P/L % Visual (text with arrows)
    if "P/L %" in df_to_show.columns:
        styled_df = styled_df.map(pl_visual_style, subset=["P/L %"])


    st.dataframe(
        styled_df,
        width="stretch",
        hide_index=True,
        column_config=active_column_config
    )

    col_val, col_invested, col_pl = st.columns(3)
    with col_val:  # Total Portfolio Value
        if 'Total Value' in display_df.columns and display_df['Total Value'].notna().any():
            total_portfolio_value = display_df['Total Value'].sum(skipna=True)
            st.metric(label=f"Total Portfolio Value ({CURRENCY_SYMBOL})", value=f"{total_portfolio_value:,.2f}")
    with col_invested:  # Amount Invested
        if 'Total Cost' in display_df.columns and display_df['Total Cost'].notna().any():
            total_amount_invested = display_df['Total Cost'].sum(skipna=True)
            st.metric(label=f"Amount Invested ({CURRENCY_SYMBOL})", value=f"{total_amount_invested:,.2f}")
    with col_pl:  # Total Profit/Loss
        if 'Profit/Loss' in display_df.columns and display_df['Profit/Loss'].notna().any():
            total_profit_loss_val = display_df['Profit/Loss'].sum(skipna=True)
            st.metric(label=f"Total Profit/Loss ({CURRENCY_SYMBOL})", value="", delta=f"{total_profit_loss_val:,.2f}")
    st.markdown("---")

    st.header("Historical Price Chart")

    chart_type = st.selectbox("Select Chart Type:", ["Line Chart", "Bar Chart"])

    # Time range selection
    range_label = st.selectbox("Select Time Range:", ["3 Months", "6 Months", "1 Year", "All"])

    range_to_months = {
        "3 Months": 3,
        "6 Months": 6,
        "1 Year": 12,
        "All": None,
    }

    if "Symbol" in live_df.columns:
        available_symbols_for_chart = sorted(
            [s for s in live_df["Symbol"].dropna().unique() if s in STOCK_ID_MAPPING]
        )
    else:
        available_symbols_for_chart = []

    if not available_symbols_for_chart:
        st.warning("No stocks for charting. Check `STOCK_ID_MAPPING` in `config.py` and sheet symbols.")
    else:
        selected_symbol = st.selectbox(
            "Select Stock for Historical Chart:",
            options=available_symbols_for_chart,
            key="selected_symbol"
        )

        ngx_specific_id = STOCK_ID_MAPPING.get(selected_symbol)
        if not ngx_specific_id:
            st.error(f"NGX chart ID not found for {selected_symbol} in `config.py`.")
        else:
            historical_df = fetch_historical_data(ngx_specific_id)

            if historical_df is None or historical_df.empty:
                st.warning("No historical data returned for this stock.")
            else:
                # Ensure correct dtypes and order
                historical_df = historical_df.copy()
                historical_df["Date"] = pd.to_datetime(historical_df["Date"], errors="coerce")
                historical_df["Price"] = pd.to_numeric(historical_df["Price"], errors="coerce")
                historical_df = historical_df.dropna(subset=["Date", "Price"]).sort_values("Date")

                if historical_df.empty:
                    st.warning("Historical data exists but could not be parsed (Date or Price invalid).")
                else:
                    # Anchor the filter to the latest date in the dataset
                    latest_date = historical_df["Date"].max()
                    months = range_to_months.get(range_label)

                    if months is not None:
                        cutoff = latest_date - pd.DateOffset(months=months)
                        filtered_df = historical_df.loc[historical_df["Date"] >= cutoff].copy()
                    else:
                        filtered_df = historical_df.copy()

                    # Helpful caption to confirm filter is actually applied
                    st.caption(
                        f"History span: {historical_df['Date'].min().date()} to {historical_df['Date'].max().date()} "
                        f"| showing {len(filtered_df)} of {len(historical_df)} points"
                    )

                    if filtered_df.empty:
                        st.warning(f"No data available for {selected_symbol} in the selected range.")
                    else:
                        title = f"{selected_symbol} Historical Price ({range_label})"

                        if chart_type == "Line Chart":
                            fig = px.line(filtered_df, x="Date", y="Price", title=title)
                        else:
                            fig = px.bar(filtered_df, x="Date", y="Price", title=title)

                        # Force x axis to the filtered range and reset zoom
                        fig.update_layout(
                            xaxis_title="Date",
                            yaxis_title=f"Price ({CURRENCY_SYMBOL})",
                            xaxis=dict(range=[filtered_df["Date"].min(), filtered_df["Date"].max()])
                        )

                        # Key forces Streamlit to re mount chart when inputs change
                        st.plotly_chart(
                            fig,
                            width="stretch",
                            key=f"hist_{selected_symbol}_{range_label}_{chart_type}"
                        )

    # st.header("Historical Price Chart")
    #
    # # Chart type selection
    # chart_type = st.selectbox("Select Chart Type:", ["Line Chart", "Bar Chart"])
    #
    # if 'Symbol' in live_df.columns:
    #     available_symbols_for_chart = sorted([s for s in live_df['Symbol'].unique() if s in STOCK_ID_MAPPING])
    # else:
    #     available_symbols_for_chart = []
    #
    # if not available_symbols_for_chart:
    #     st.warning("No stocks for charting. Check `STOCK_ID_MAPPING` in `config.py` & sheet symbols.")
    # else:
    #     selected_symbol = st.selectbox("Select Stock for Historical Chart:", options=available_symbols_for_chart)
    #     if selected_symbol:
    #         ngx_specific_id = STOCK_ID_MAPPING.get(selected_symbol)
    #         if ngx_specific_id:
    #             historical_df = fetch_historical_data(ngx_specific_id)
    #             if not historical_df.empty:
    #                 fig = None
    #                 if chart_type == "Line Chart":
    #                     fig = px.line(historical_df, x='Date', y='Price',
    #                                   title=f"{selected_symbol} Historical Price (Line)")
    #                 elif chart_type == "Bar Chart":
    #                     fig = px.bar(historical_df, x='Date', y='Price',
    #                                  title=f"{selected_symbol} Historical Price (Bar)")
    #
    #                 if fig:
    #                     fig.update_layout(xaxis_title="Date", yaxis_title=f"Price ({CURRENCY_SYMBOL})")
    #                     st.plotly_chart(fig, width="stretch")
    #
    #
    #         else:
    #             st.error(f"NGX chart ID not found for {selected_symbol} in `config.py`.")
else:
    st.warning("Could not load live data. Check Google Sheet connection and Apps Script.")

if st.button("🔄 Refresh Data Cache & Rerun Script"):
    st.cache_data.clear()
    st.success("Data cache cleared. Rerunning script...")
    st.rerun()