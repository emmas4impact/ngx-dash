
import streamlit as st
import plotly.express as px
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
st.title("📈 My Nigerian Stock Exchange Portfolio Dashboard")

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

# if check_auto_refresh_conditions(market_status):
#     st_autorefresh(interval=REFRESH_INTERVAL_SECONDS * 1000, key="dashboard_autorefresh")
# st.markdown("---")

st.sidebar.header("Stock ID Mapping for Charts")
st.sidebar.info("Ensure `STOCK_ID_MAPPING` in `config file` is correct.")
st.sidebar.json(STOCK_ID_MAPPING, expanded=False)

live_df = load_live_data_from_gsheet()

if not live_df.empty:
    st.header("My Portfolio Snapshot")

    display_df = live_df.copy()

    if "P/L %" in display_df.columns:
        def color_pl(val):
            try:
                val_float = float(val)
                if val_float > 0:
                    return f"<span style='color: green; font-weight:600;'>{val_float:.2f}%</span>"
                elif val_float < 0:
                    return f"<span style='color: red; font-weight:600;'>{val_float:.2f}%</span>"
                else:
                    return f"<span style='color: gray;'>{val_float:.2f}%</span>"
            except:
                return val


        display_df["P/L % Visual"] = display_df["P/L %"].apply(color_pl)

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
        "P/L %": st.column_config.NumberColumn(format="%.2f%%"),
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


    df_to_show = display_df[final_cols_to_display].copy()

    cols_to_color = [c for c in ["Profit/Loss", "P/L %"] if c in df_to_show.columns]
    styled_df = df_to_show.style
    if cols_to_color:
        styled_df = styled_df.map(pl_style, subset=cols_to_color)

    st.dataframe(
        styled_df,
        width="stretch",
        hide_index=True,
        column_config=active_column_config
    )
    # df_to_show = display_df[final_cols_to_display]
    #
    # pl_columns_to_color = [
    #     col for col in ["Profit/Loss", "P/L %", "P/L % Visual"]
    #     if col in df_to_show.columns
    # ]
    #
    # styled_df = df_to_show.style
    # if pl_columns_to_color:
    #     styled_df = styled_df.map(pl_style, subset=pl_columns_to_color)
    #
    # st.dataframe(
    #     styled_df,
    #     width="stretch",
    #     hide_index=True,
    #     column_config=active_column_config
    # )

    # st.dataframe(
    #     display_df[final_cols_to_display],
    #     use_container_width=True,
    #     hide_index=True,
    #     column_config=active_column_config
    # )
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