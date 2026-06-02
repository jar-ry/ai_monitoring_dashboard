"""Raw ACCOUNT_USAGE export queries for the Raw Data tab."""
import logging
import streamlit as st
import pandas as pd
from utils import format_date_param, DEFAULT_TIMEZONE, local_dates_to_utc_range
logger = logging.getLogger(__name__)


@st.cache_data(ttl=300, show_spinner=False)
def get_cortex_analyst_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT START_TIME, USERNAME, REQUEST_COUNT, CREDITS FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' ORDER BY START_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_cortex_search_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try: return _session.sql(f"SELECT USAGE_DATE as DATE, DATABASE_NAME, SCHEMA_NAME, SERVICE_NAME, CONSUMPTION_TYPE, CREDITS, TOKENS FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' ORDER BY USAGE_DATE DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_cortex_search_batch_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT START_TIME, QUERY_ID, SERVICE_NAME, CONSUMPTION_TYPE, CREDITS_USED, MODEL_NAME, TOKENS FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_BATCH_QUERY_USAGE_HISTORY WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' ORDER BY START_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_document_ai_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT START_TIME, FUNCTION_NAME, MODEL_NAME, OPERATION_NAME, PAGE_COUNT, DOCUMENT_COUNT, CREDITS_USED as CREDITS FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' ORDER BY START_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_cortex_code_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    cli = f"SELECT c.USAGE_TIME, COALESCE(u.NAME,CAST(c.USER_ID AS VARCHAR)) AS USER_NAME, c.TOKEN_CREDITS as CREDITS, c.TOKENS, 'CLI' as SOURCE FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY c LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON c.USER_ID=u.USER_ID WHERE c.USAGE_TIME>='{utc_s}' AND c.USAGE_TIME<='{utc_e}'"
    ss = f"SELECT c.USAGE_TIME, COALESCE(u.NAME,CAST(c.USER_ID AS VARCHAR)) AS USER_NAME, c.TOKEN_CREDITS as CREDITS, c.TOKENS, 'SNOWSIGHT' as SOURCE FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY c LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON c.USER_ID=u.USER_ID WHERE c.USAGE_TIME>='{utc_s}' AND c.USAGE_TIME<='{utc_e}'"
    try: return _session.sql(f"{cli} UNION ALL {ss} ORDER BY USAGE_TIME DESC LIMIT 10000").to_pandas()
    except Exception:
        for q in [cli+" ORDER BY USAGE_TIME DESC LIMIT 10000", ss+" ORDER BY USAGE_TIME DESC LIMIT 10000"]:
            try: return _session.sql(q).to_pandas()
            except Exception: continue
        return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_provisioned_throughput_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT INTERVAL_START_TIME, MODEL_NAME, PTU_COUNT, PTU_CREDITS as CREDITS FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY WHERE INTERVAL_START_TIME>='{utc_s}' AND INTERVAL_START_TIME<='{utc_e}' ORDER BY INTERVAL_START_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_fine_tuning_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT START_TIME, MODEL_NAME, TOKEN_CREDITS, TOKENS FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FINE_TUNING_USAGE_HISTORY WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' ORDER BY START_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_cortex_agent_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT START_TIME, AGENT_NAME, USER_NAME, TOKEN_CREDITS, TOKENS, REQUEST_ID FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' ORDER BY START_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_snowflake_intelligence_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT START_TIME, USER_NAME, SNOWFLAKE_INTELLIGENCE_NAME, AGENT_NAME, TOKEN_CREDITS, TOKENS FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' ORDER BY START_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_rest_api_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT USAGE_TIME, MODEL_NAME, USER_ID, TOKENS FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY WHERE USAGE_TIME>='{utc_s}' AND USAGE_TIME<='{utc_e}' ORDER BY USAGE_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=300, show_spinner=False)
def get_cortex_ai_functions_usage(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try: return _session.sql(f"SELECT USAGE_TIME, FUNCTION_NAME, MODEL_NAME, QUERY_ID, USER_ID, QUERY_TAG, TOKEN_CREDITS AS CREDITS, TOKENS FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AISQL_USAGE_HISTORY WHERE USAGE_TIME>='{utc_s}' AND USAGE_TIME<='{utc_e}' ORDER BY USAGE_TIME DESC LIMIT 10000").to_pandas()
    except Exception: return pd.DataFrame()
