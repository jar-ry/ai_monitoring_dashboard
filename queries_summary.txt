"""
Pre-aggregated summary table queries for the AI Monitoring Dashboard.
"""
import logging
from typing import Dict, List
import pandas as pd
import streamlit as st
from config import SUMMARY_SCHEMA, DEFAULT_TIMEZONE
from utils import _safe_float, _safe_int, format_date_param, escape_sql_literal, local_dates_to_utc_range

logger = logging.getLogger(__name__)


@st.cache_data(ttl=60, show_spinner=False)
def get_metering_ai_trend(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT USAGE_DATE AS DATE, SERVICE_TYPE, SUM(CREDITS_USED) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
        WHERE SERVICE_TYPE IN ('AI_SERVICES','CORTEX_CODE_CLI','CORTEX_CODE_SNOWSIGHT','SNOWFLAKE_INTELLIGENCE','CORTEX_AGENTS')
          AND USAGE_DATE BETWEEN '{s}' AND '{e}' GROUP BY 1,2 ORDER BY 1""").to_pandas()
    except Exception as ex:
        logger.warning(f"metering: {ex}")
        return pd.DataFrame(columns=['DATE','SERVICE_TYPE','CREDITS'])


@st.cache_data(ttl=60, show_spinner="Loading summary...")
def get_ai_services_summary(_session, start_date: str, end_date: str) -> Dict:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        df = _session.sql(f"""SELECT COALESCE(SUM(TOTAL_CREDITS),0) as total_credits, COALESCE(SUM(TOTAL_TOKENS),0) as total_tokens,
            COALESCE(SUM(TOTAL_CALLS),0) as total_calls, COUNT(DISTINCT USAGE_DATE) as active_days
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'""").to_pandas()
        if df.empty: return {'total_credits':0,'total_tokens':0,'total_calls':0,'active_days':0}
        return {'total_credits':_safe_float(df['TOTAL_CREDITS'].iloc[0]),'total_tokens':_safe_int(df['TOTAL_TOKENS'].iloc[0]),
                'total_calls':_safe_int(df['TOTAL_CALLS'].iloc[0]),'active_days':_safe_int(df['ACTIVE_DAYS'].iloc[0])}
    except Exception as ex:
        logger.warning(f"summary: {ex}")
        return {'total_credits':0,'total_tokens':0,'total_calls':0,'active_days':0}


@st.cache_data(ttl=60, show_spinner=False)
def get_credits_by_day_and_type(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT USAGE_DATE as DATE,
            CASE WHEN CATEGORY IN ('Cortex Agents','Cortex Code','Snowflake Intelligence') THEN 'AI Credits'
                 WHEN CATEGORY='Cortex REST API' THEN 'Dollars' ELSE 'Regular Credits' END as CREDIT_TYPE,
            COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'
        GROUP BY 1,CREDIT_TYPE ORDER BY 1""").to_pandas()
    except Exception as ex:
        logger.warning(f"daily_type: {ex}")
        return pd.DataFrame(columns=['DATE','CREDIT_TYPE','CREDITS'])


@st.cache_data(ttl=60, show_spinner="Loading features...")
def get_feature_usage(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT FEATURE_NAME as FEATURE, CATEGORY,
            COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS, COALESCE(SUM(TOTAL_TOKENS),0) as TOKENS,
            COALESCE(SUM(INPUT_TOKENS),0) as INPUT_TOKENS, COALESCE(SUM(OUTPUT_TOKENS),0) as OUTPUT_TOKENS,
            COALESCE(SUM(TOTAL_CALLS),0) as CALLS, COALESCE(SUM(UNIQUE_USERS),0) as UNIQUE_USERS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'
        GROUP BY FEATURE_NAME, CATEGORY ORDER BY CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"features: {ex}")
        return pd.DataFrame(columns=['FEATURE','CATEGORY','CREDITS','TOKENS','INPUT_TOKENS','OUTPUT_TOKENS','CALLS','UNIQUE_USERS'])


@st.cache_data(ttl=60, show_spinner=False)
def get_top_users(_session, start_date: str, end_date: str, limit: int = 20) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT USER_NAME, COALESCE(SUM(TOTAL_CREDITS),0) as TOTAL_CREDITS,
            COALESCE(SUM(TOTAL_TOKENS),0) as TOTAL_TOKENS, COALESCE(SUM(TOTAL_CALLS),0) as TOTAL_CALLS,
            LISTAGG(DISTINCT FEATURE_NAME,', ') WITHIN GROUP (ORDER BY FEATURE_NAME) as FEATURES_USED
        FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'
        GROUP BY USER_NAME ORDER BY TOTAL_CREDITS DESC LIMIT {limit}""").to_pandas()
    except Exception as ex:
        logger.warning(f"users: {ex}")
        return pd.DataFrame(columns=['USER_NAME','TOTAL_CREDITS','TOTAL_TOKENS','TOTAL_CALLS','FEATURES_USED'])


@st.cache_data(ttl=60, show_spinner=False)
def get_model_usage(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT MODEL_NAME, COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS,
            COALESCE(SUM(TOTAL_TOKENS),0) as TOKENS, COALESCE(SUM(INPUT_TOKENS),0) as INPUT_TOKENS,
            COALESCE(SUM(OUTPUT_TOKENS),0) as OUTPUT_TOKENS, COALESCE(SUM(TOTAL_CALLS),0) as CALLS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_MODEL_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'
        GROUP BY MODEL_NAME ORDER BY CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"models: {ex}")
        return pd.DataFrame(columns=['MODEL_NAME','CREDITS','TOKENS','INPUT_TOKENS','OUTPUT_TOKENS','CALLS'])


@st.cache_data(ttl=60, show_spinner=False)
def get_top_users_by_feature(_session, start_date: str, end_date: str, feature: str, limit: int = 10) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT USER_NAME, COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS, COALESCE(SUM(TOTAL_CALLS),0) as CALLS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' AND FEATURE_NAME='{escape_sql_literal(feature)}'
        GROUP BY USER_NAME ORDER BY CREDITS DESC LIMIT {limit}""").to_pandas()
    except Exception as ex:
        logger.warning(f"users_feature: {ex}")
        return pd.DataFrame(columns=['USER_NAME','CREDITS','CALLS'])


@st.cache_data(ttl=60, show_spinner=False)
def get_users_by_feature_summary(_session, start_date: str, end_date: str, feature: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT USER_NAME, SUM(TOTAL_CREDITS) AS CREDITS, SUM(TOTAL_TOKENS) AS TOKENS, SUM(TOTAL_CALLS) AS CALLS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' AND FEATURE_NAME='{escape_sql_literal(feature)}'
        GROUP BY 1 ORDER BY CREDITS DESC LIMIT 15""").to_pandas()
    except Exception as ex:
        logger.warning(f"users_by_feat: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_models_by_feature(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT CATEGORY, MODEL_NAME, SUM(TOTAL_CREDITS) AS CREDITS, SUM(TOTAL_TOKENS) AS TOKENS, SUM(TOTAL_CALLS) AS CALLS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' AND MODEL_NAME != 'N/A'
        GROUP BY 1,2 ORDER BY CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"models_by_feat: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner="Comparing periods...")
def get_period_comparison(_session, start_date: str, end_date: str, prev_start: str, prev_end: str) -> Dict:
    s, e = format_date_param(start_date), format_date_param(end_date)
    ps, pe = format_date_param(prev_start), format_date_param(prev_end)
    try:
        df = _session.sql(f"""
        WITH cp AS (SELECT COALESCE(SUM(TOTAL_CREDITS),0) as credits, COALESCE(SUM(TOTAL_TOKENS),0) as tokens, COALESCE(SUM(TOTAL_CALLS),0) as calls FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'),
        pp AS (SELECT COALESCE(SUM(TOTAL_CREDITS),0) as credits, COALESCE(SUM(TOTAL_TOKENS),0) as tokens, COALESCE(SUM(TOTAL_CALLS),0) as calls FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{ps}' AND '{pe}'),
        cu AS (SELECT COUNT(DISTINCT USER_NAME) as users FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'),
        pu AS (SELECT COUNT(DISTINCT USER_NAME) as users FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{ps}' AND '{pe}')
        SELECT cp.credits as current_credits,pp.credits as prev_credits,cp.tokens as current_tokens,pp.tokens as prev_tokens,
               cp.calls as current_calls,pp.calls as prev_calls,cu.users as current_users,pu.users as prev_users
        FROM cp,pp,cu,pu""").to_pandas()
        if df.empty: return {}
        row = df.iloc[0]
        return {k.lower():_safe_float(row.get(k.upper())) for k in ['current_credits','prev_credits','current_tokens','prev_tokens','current_calls','prev_calls','current_users','prev_users']}
    except Exception as ex:
        logger.warning(f"comparison: {ex}")
        return {}


@st.cache_data(ttl=60, show_spinner=False)
def get_category_breakdown(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT CATEGORY, COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS, COALESCE(SUM(TOTAL_CALLS),0) as CALLS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' GROUP BY CATEGORY ORDER BY CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"category: {ex}")
        return pd.DataFrame(columns=['CATEGORY','CREDITS','CALLS'])


@st.cache_data(ttl=60, show_spinner=False)
def get_daily_trend_by_category(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT USAGE_DATE as DATE, CATEGORY, COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' GROUP BY 1,2 ORDER BY 1""").to_pandas()
    except Exception as ex:
        logger.warning(f"daily_cat: {ex}")
        return pd.DataFrame(columns=['DATE','CATEGORY','CREDITS'])


@st.cache_data(ttl=60, show_spinner=False)
def get_daily_trend_by_feature(_session, start_date: str, end_date: str, feature: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    feat = escape_sql_literal(feature)
    try:
        return _session.sql(f"""SELECT USAGE_DATE as DATE, COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'
        AND FEATURE = '{feat}' GROUP BY 1 ORDER BY 1""").to_pandas()
    except Exception as ex:
        logger.warning(f"daily_feat: {ex}")
        return pd.DataFrame(columns=['DATE', 'CREDITS'])


@st.cache_data(ttl=60, show_spinner=False)
def get_user_growth(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT USAGE_DATE as DATE, COUNT(DISTINCT USER_NAME) as UNIQUE_USERS, COALESCE(SUM(TOTAL_CALLS),0) as TOTAL_CALLS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' GROUP BY 1 ORDER BY 1""").to_pandas()
    except Exception as ex:
        logger.warning(f"growth: {ex}")
        return pd.DataFrame(columns=['DATE','UNIQUE_USERS','TOTAL_CALLS'])


@st.cache_data(ttl=60, show_spinner=False)
def get_efficiency_metrics(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT MODEL_NAME, COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS, COALESCE(SUM(TOTAL_TOKENS),0) as TOKENS,
            COALESCE(SUM(TOTAL_CALLS),0) as CALLS,
            CASE WHEN SUM(TOTAL_CREDITS)>0 THEN ROUND(SUM(TOTAL_TOKENS)/SUM(TOTAL_CREDITS),0) ELSE 0 END as TOKENS_PER_CREDIT
        FROM {SUMMARY_SCHEMA}.AI_USAGE_MODEL_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' AND MODEL_NAME IS NOT NULL AND MODEL_NAME!='N/A'
        GROUP BY MODEL_NAME HAVING SUM(TOTAL_CREDITS)>0 ORDER BY CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"efficiency: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_new_users(_session, start_date: str, end_date: str, prev_start: str, prev_end: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    ps, pe = format_date_param(prev_start), format_date_param(prev_end)
    try:
        return _session.sql(f"""WITH curr AS (SELECT DISTINCT USER_NAME FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'),
        prev AS (SELECT DISTINCT USER_NAME FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{ps}' AND '{pe}')
        SELECT curr.USER_NAME FROM curr LEFT JOIN prev ON curr.USER_NAME=prev.USER_NAME WHERE prev.USER_NAME IS NULL""").to_pandas()
    except Exception as ex:
        logger.warning(f"new_users: {ex}")
        return pd.DataFrame(columns=['USER_NAME'])


@st.cache_data(ttl=60, show_spinner=False)
def get_wow_comparison(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT DATE_TRUNC('WEEK',USAGE_DATE)::DATE as WEEK_START,
            COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS, COALESCE(SUM(TOTAL_CALLS),0) as CALLS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' GROUP BY 1 ORDER BY 1""").to_pandas()
    except Exception as ex:
        logger.warning(f"wow: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_agents_overview(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try:
        return _session.sql(f"""SELECT AGENT_NAME, AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME,
            COUNT(*) AS REQUESTS, COUNT(DISTINCT USER_NAME) AS UNIQUE_USERS,
            COALESCE(SUM(TOKEN_CREDITS),0) AS CREDITS, COALESCE(SUM(TOKENS),0) AS TOKENS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
        WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' AND AGENT_NAME IS NOT NULL
        GROUP BY 1,2,3 ORDER BY CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"agents: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_agents_token_breakdown(_session, agent_name: str, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try:
        return _session.sql(f"""SELECT f.value:service_type::STRING AS SERVICE_TYPE, f.value:model::STRING AS MODEL,
            SUM(TRY_TO_NUMBER(f.value:input::VARCHAR)) AS INPUT_TOKENS, SUM(TRY_TO_NUMBER(f.value:output::VARCHAR)) AS OUTPUT_TOKENS,
            SUM(TRY_TO_NUMBER(f.value:cache_read_input::VARCHAR)) AS CACHE_READ, SUM(TRY_TO_NUMBER(f.value:cache_write_input::VARCHAR)) AS CACHE_WRITE
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY, LATERAL FLATTEN(input=>TOKENS_GRANULAR) f
        WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' AND AGENT_NAME='{escape_sql_literal(agent_name)}'
        GROUP BY 1,2 ORDER BY INPUT_TOKENS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"agent_tokens: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_agent_health_scorecard(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try:
        return _session.sql(f"""SELECT AGENT_NAME, COUNT(*) AS REQUESTS, ROUND(AVG(TOKENS),0) AS AVG_TOKENS, MAX(TOKENS) AS MAX_TOKENS,
            ROUND(100.0*COUNT(CASE WHEN TOKENS>128000 THEN 1 END)/NULLIF(COUNT(*),0),1) AS PCT_OVER_128K,
            COALESCE(SUM(TOKEN_CREDITS),0) AS TOTAL_CREDITS,
            CASE WHEN 100.0*COUNT(CASE WHEN TOKENS>128000 THEN 1 END)/NULLIF(COUNT(*),0)>20 THEN 'HIGH'
                 WHEN 100.0*COUNT(CASE WHEN TOKENS>128000 THEN 1 END)/NULLIF(COUNT(*),0)>5 THEN 'MEDIUM' ELSE 'LOW' END AS RISK_LEVEL
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
        WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' AND AGENT_NAME IS NOT NULL
        GROUP BY AGENT_NAME ORDER BY TOTAL_CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"health: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_high_token_users(_session, start_date: str, end_date: str, user_tz: str = DEFAULT_TIMEZONE) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    utc_s, utc_e = local_dates_to_utc_range(s, e, user_tz)
    try:
        return _session.sql(f"""SELECT USER_NAME, AGENT_NAME, COUNT(*) AS REQUESTS, ROUND(AVG(TOKENS),0) AS AVG_TOKENS, COALESCE(SUM(TOKEN_CREDITS),0) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY WHERE START_TIME>='{utc_s}' AND START_TIME<='{utc_e}' AND TOKENS>50000
        GROUP BY 1,2 ORDER BY AVG_TOKENS DESC LIMIT 20""").to_pandas()
    except Exception as ex:
        logger.warning(f"high_token: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_snowflake_native_budgets(_session) -> pd.DataFrame:
    try:
        df = _session.sql("SHOW BUDGETS IN ACCOUNT").to_pandas()
        df.columns = [c.lower() for c in df.columns]
        return df
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_cortex_search_credits(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT SERVICE_NAME, CONSUMPTION_TYPE, COALESCE(SUM(CREDITS),0) AS CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'
        GROUP BY 1,2 ORDER BY CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"search_credits: {ex}")
        return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_wh_cost_by_user(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT qh.USER_NAME, COALESCE(SUM(q.CREDITS_ATTRIBUTED_COMPUTE),0) AS WH_CREDITS
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY q
        JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh ON q.QUERY_ID=qh.QUERY_ID
        WHERE qh.START_TIME BETWEEN '{s}' AND '{e}'
          AND qh.QUERY_ID IN (SELECT DISTINCT QUERY_ID FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AISQL_USAGE_HISTORY WHERE USAGE_TIME BETWEEN '{s}' AND '{e}')
        GROUP BY 1 ORDER BY WH_CREDITS DESC""").to_pandas()
    except Exception as ex:
        logger.warning(f"wh_cost: {ex}")
        return pd.DataFrame(columns=['USER_NAME','WH_CREDITS'])


@st.cache_data(ttl=60, show_spinner=False)
def get_refresh_log(_session, limit: int = 15) -> pd.DataFrame:
    try:
        return _session.sql(f"""SELECT REFRESH_ID, REFRESH_START, REFRESH_END, REFRESH_MODE, STATUS, SOURCE_ERRORS,
            DATEDIFF(second,REFRESH_START,REFRESH_END) as DURATION_SEC
        FROM {SUMMARY_SCHEMA}.AI_USAGE_REFRESH_LOG ORDER BY REFRESH_START DESC LIMIT {int(limit)}""").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_task_history(_session) -> pd.DataFrame:
    try:
        return _session.sql("""SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE,
            DATEDIFF(second,SCHEDULED_TIME,COMPLETED_TIME) as DURATION_SEC
        FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME=>'REFRESH_AI_USAGE_TASK',RESULT_LIMIT=>20)) ORDER BY SCHEDULED_TIME DESC""").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_data_completeness(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT CATEGORY, COUNT(DISTINCT FEATURE_NAME) as FEATURES,
            COALESCE(SUM(TOTAL_CREDITS),0) as CREDITS, MIN(USAGE_DATE) as FIRST_DATE, MAX(USAGE_DATE) as LAST_DATE
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' GROUP BY CATEGORY ORDER BY CREDITS DESC""").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_data_reconciliation(_session, start_date: str, end_date: str) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""SELECT 'Summary Tables' as SOURCE, COALESCE(SUM(TOTAL_CREDITS),0) as TOTAL_CREDITS
        FROM {SUMMARY_SCHEMA}.AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}'
        UNION ALL SELECT 'Metering (All AI)', COALESCE(SUM(CREDITS_USED),0)
        FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
        WHERE SERVICE_TYPE IN ('AI_SERVICES','CORTEX_CODE_CLI','CORTEX_CODE_SNOWSIGHT','SNOWFLAKE_INTELLIGENCE','CORTEX_AGENTS') AND USAGE_DATE BETWEEN '{s}' AND '{e}'""").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_user_anomalies(_session, start_date: str, end_date: str, multiplier: float = 3) -> pd.DataFrame:
    s, e = format_date_param(start_date), format_date_param(end_date)
    try:
        return _session.sql(f"""WITH curr AS (SELECT USER_NAME, SUM(TOTAL_CREDITS) as CC FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE BETWEEN '{s}' AND '{e}' GROUP BY 1),
        hist AS (SELECT USER_NAME, AVG(dc) as AD FROM (SELECT USER_NAME, USAGE_DATE, SUM(TOTAL_CREDITS) as dc FROM {SUMMARY_SCHEMA}.AI_USAGE_USER_SUMMARY WHERE USAGE_DATE<'{s}' GROUP BY 1,2) GROUP BY 1 HAVING COUNT(*)>=3)
        SELECT curr.USER_NAME, curr.CC as CURRENT_CREDITS, hist.AD as AVG_DAILY, ROUND(curr.CC/NULLIF(hist.AD,0),1) as MULTIPLIER
        FROM curr JOIN hist ON curr.USER_NAME=hist.USER_NAME WHERE curr.CC>hist.AD*{multiplier} ORDER BY MULTIPLIER DESC LIMIT 10""").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_last_refresh_time(_session) -> str:
    try:
        df = _session.sql(f"""SELECT REFRESH_END, REFRESH_MODE FROM {SUMMARY_SCHEMA}.AI_USAGE_REFRESH_LOG
        WHERE STATUS IN ('SUCCESS','PARTIAL') ORDER BY REFRESH_END DESC LIMIT 1""").to_pandas()
        if df.empty or pd.isna(df['REFRESH_END'].iloc[0]): return "Never"
        ts = df['REFRESH_END'].iloc[0].strftime("%Y-%m-%d %H:%M")
        mode = df['REFRESH_MODE'].iloc[0] if not pd.isna(df['REFRESH_MODE'].iloc[0]) else ""
        return f"{ts} ({mode})" if mode else ts
    except Exception: return "Unknown"


def get_health_status(total_credits: float, prev_credits: float, top_users: pd.DataFrame, period_days: int) -> List[Dict]:
    issues = []
    if prev_credits > 0:
        ratio = total_credits / prev_credits
        if ratio >= 3: issues.append({'severity':'🔴','message':f"Spend {ratio:.1f}x vs prior",'action':"Check Top Users"})
        elif ratio >= 2: issues.append({'severity':'⚠️','message':f"Spend doubled ({ratio:.1f}x)",'action':"Review contributors"})
    if not top_users.empty and 'TOTAL_CREDITS' in top_users.columns and total_credits > 0:
        top_pct = (_safe_float(top_users['TOTAL_CREDITS'].iloc[0]) / total_credits) * 100
        if top_pct > 70: issues.append({'severity':'⚠️','message':f"Top user={top_pct:.0f}% of spend",'action':"Review concentration"})
    if total_credits == 0: issues.append({'severity':'💡','message':"No AI usage detected",'action':"Check data refresh"})
    if not issues: issues.append({'severity':'✅','message':"All systems normal",'action':None})
    return issues
