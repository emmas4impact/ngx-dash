
import streamlit as st
import plotly.express as px
from streamlit_autorefresh import st_autorefresh

from config import (
    STOCK_ID_MAPPING, REFRESH_INTERVAL_SECONDS, COLS_TO_DISPLAY,
    CURRENCY_SYMBOL  # Assuming COLS_TO_DISPLAY will be adjusted
)

from data_loader import load_live_data_from_gsheet, fetch_historical_data, fetch_market_status

from refresh_utils import check_auto_refresh_conditions

st.set_page_config(layout="wide")
st.title("📈 My Nigerian Stock Exchange Portfolio Dashboard")

market_status = fetch_market_status()
st.subheader(f"Market Status: {market_status}")
st.sidebar.markdown("---")



if check_auto_refresh_conditions(market_status):
    st_autorefresh(interval=REFRESH_INTERVAL_SECONDS * 1000, key="dashboard_autorefresh")
st.markdown("---")

st.sidebar.header("Stock ID Mapping for Charts")
st.sidebar.info("Ensure `STOCK_ID_MAPPING` in `config file` is correct.")
st.sidebar.json(STOCK_ID_MAPPING, expanded=False)

live_df = load_live_data_from_gsheet()

if not live_df.empty:
    st.header("My Portfolio Snapshot")

    display_df = live_df.copy()

    cols_to_display_updated = []
    for col in COLS_TO_DISPLAY:  # COLS_TO_DISPLAY is from config.py
        if col == 'P/L %' and 'P/L % Visual' in display_df.columns:
            cols_to_display_updated.append('P/L % Visual')
        elif col in display_df.columns:
            cols_to_display_updated.append(col)
    final_cols_to_display = cols_to_display_updated

    column_config = {
        "Current Value": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "Total Value": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "Avg. Purchase Price": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "Total Cost": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "Profit/Loss": st.column_config.NumberColumn(format=f"{CURRENCY_SYMBOL}%.2f"),
        "P/L % Visual": st.column_config.TextColumn(label="P/L %"),  # Display string, label header as "P/L %"
        "Percent Change": st.column_config.NumberColumn(format="%.2f"),
        "Quantity": st.column_config.NumberColumn(format="%d"),  # Integer format
        "Last Updated": st.column_config.DatetimeColumn(format="YYYY-MM-DD HH:mm:ss")
    }
    active_column_config = {k: v for k, v in column_config.items() if k in final_cols_to_display}

    st.dataframe(
        display_df[final_cols_to_display],
        use_container_width=True,
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

    # Chart type selection
    chart_type = st.selectbox("Select Chart Type:", ["Line Chart", "Bar Chart"])

    if 'Symbol' in live_df.columns:
        available_symbols_for_chart = sorted([s for s in live_df['Symbol'].unique() if s in STOCK_ID_MAPPING])
    else:
        available_symbols_for_chart = []

    if not available_symbols_for_chart:
        st.warning("No stocks for charting. Check `STOCK_ID_MAPPING` in `config.py` & sheet symbols.")
    else:
        selected_symbol = st.selectbox("Select Stock for Historical Chart:", options=available_symbols_for_chart)
        if selected_symbol:
            ngx_specific_id = STOCK_ID_MAPPING.get(selected_symbol)
            if ngx_specific_id:
                historical_df = fetch_historical_data(ngx_specific_id)
                if not historical_df.empty:
                    fig = None
                    if chart_type == "Line Chart":
                        fig = px.line(historical_df, x='Date', y='Price',
                                      title=f"{selected_symbol} Historical Price (Line)")
                    elif chart_type == "Bar Chart":
                        fig = px.bar(historical_df, x='Date', y='Price',
                                     title=f"{selected_symbol} Historical Price (Bar)")

                    if fig:
                        fig.update_layout(xaxis_title="Date", yaxis_title=f"Price ({CURRENCY_SYMBOL})")
                        st.plotly_chart(fig, use_container_width=True)

            else:
                st.error(f"NGX chart ID not found for {selected_symbol} in `config.py`.")
else:
    st.warning("Could not load live data. Check Google Sheet connection and Apps Script.")

if st.button("🔄 Refresh Data Cache & Rerun Script"):
    st.cache_data.clear()
    st.success("Data cache cleared. Rerunning script...")
    st.rerun()