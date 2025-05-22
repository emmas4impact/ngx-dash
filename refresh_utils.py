
import streamlit as st
from datetime import datetime, time as dt_time
import pytz
from config import GMT_OFFSET_FOR_REFRESH, MARKET_OPEN_HOUR, MARKET_CLOSE_HOUR, MARKET_CLOSED_KEYWORDS


def check_auto_refresh_conditions(market_status_val):
    try:
        target_tz_str = f'Etc/GMT-{GMT_OFFSET_FOR_REFRESH}'
        target_tz = pytz.timezone(target_tz_str)
        now_target_tz = datetime.now(target_tz)

        current_time_str = now_target_tz.strftime('%Y-%m-%d %H:%M:%S %Z%z')
        refresh_status_message = f"Auto-refresh ({target_tz_str} {current_time_str}): "

        if now_target_tz.weekday() >= 5:
            refresh_status_message += "Weekend. OFF."
            st.sidebar.caption(refresh_status_message)
            return False

        current_hour = now_target_tz.hour
        if not (MARKET_OPEN_HOUR <= current_hour < MARKET_CLOSE_HOUR):
            refresh_status_message += f"Outside trading hours. OFF."
            st.sidebar.caption(refresh_status_message)
            return False

        if isinstance(market_status_val, str):
            market_status_upper = market_status_val.upper()
            if any(keyword in market_status_upper for keyword in MARKET_CLOSED_KEYWORDS):
                refresh_status_message += f"Market '{market_status_val}'. OFF."
                st.sidebar.caption(refresh_status_message)
                return False
        else:
            refresh_status_message += f"Market status '{market_status_val}' (unexpected). OFF."
            st.sidebar.caption(refresh_status_message)
            return False

        refresh_status_message += "Conditions met. Active."
        st.sidebar.caption(refresh_status_message)
        return True
    except Exception as e:
        st.sidebar.error(f"Refresh check error: {e}")
        return False