"""Agent observability queries from SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS."""
import logging
import streamlit as st
import pandas as pd
from typing import Dict
from utils import escape_sql_literal, _safe_float, _safe_int
logger = logging.getLogger(__name__)
_OBS = "SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS"


def _af(adb: str, asc: str, aname: str, days: int) -> str:
    return (f"SCOPE:name='snow.cortex.agent' AND RECORD_ATTRIBUTES:\"snow.ai.observability.database.name\"::STRING='{escape_sql_literal(adb)}' "
            f"AND RECORD_ATTRIBUTES:\"snow.ai.observability.schema.name\"::STRING='{escape_sql_literal(asc)}' "
            f"AND RECORD_ATTRIBUTES:\"snow.ai.observability.object.name\"::STRING='{escape_sql_literal(aname)}' "
            f"AND TIMESTAMP>=DATEADD(day,-{int(days)},CURRENT_TIMESTAMP())")


@st.cache_data(ttl=60, show_spinner=False)
def discover_agents(_session) -> pd.DataFrame:
    try: return _session.sql("""SELECT DISTINCT AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME, AGENT_NAME FROM (
        SELECT AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME, AGENT_NAME FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY WHERE START_TIME>=DATEADD(day,-30,CURRENT_TIMESTAMP()) AND AGENT_NAME IS NOT NULL
        UNION SELECT AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME, AGENT_NAME FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY WHERE START_TIME>=DATEADD(day,-30,CURRENT_TIMESTAMP()) AND AGENT_NAME IS NOT NULL) ORDER BY 1,2,3""").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_obs_usage_summary(_session, adb: str, asc: str, aname: str, days: int) -> Dict:
    try:
        df = _session.sql(f"SELECT COUNT(*) AS total_requests, COUNT(DISTINCT RESOURCE_ATTRIBUTES:\"snow.user.name\"::STRING) AS unique_users, COUNT(DISTINCT RECORD_ATTRIBUTES:\"snow.ai.observability.agent.thread_id\"::STRING) AS conversations FROM {_OBS} WHERE RECORD:\"name\"::STRING='CORTEX_AGENT_REQUEST' AND {_af(adb,asc,aname,days)}").to_pandas()
        if df.empty: return {}
        r = df.iloc[0]; total=_safe_int(r.get("TOTAL_REQUESTS")); users=_safe_int(r.get("UNIQUE_USERS"))
        return {"total_requests":total,"unique_users":users,"conversations":_safe_int(r.get("CONVERSATIONS")),"requests_per_user":round(total/users,1) if users>0 else 0}
    except Exception: return {}


@st.cache_data(ttl=60, show_spinner=False)
def get_obs_daily_trend(_session, adb: str, asc: str, aname: str, days: int) -> pd.DataFrame:
    try: return _session.sql(f"SELECT DATE(TIMESTAMP) AS DS, COUNT(*) AS REQUESTS FROM {_OBS} WHERE RECORD:\"name\"::STRING='CORTEX_AGENT_REQUEST' AND {_af(adb,asc,aname,days)} GROUP BY 1 ORDER BY 1").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_obs_performance(_session, adb: str, asc: str, aname: str, days: int) -> Dict:
    try:
        df = _session.sql(f"SELECT ROUND(AVG(VALUE:\"snow.ai.observability.response_time_ms\"::FLOAT),0) AS avg_ms, ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY VALUE:\"snow.ai.observability.response_time_ms\"::FLOAT),0) AS p50_ms, ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY VALUE:\"snow.ai.observability.response_time_ms\"::FLOAT),0) AS p90_ms, ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY VALUE:\"snow.ai.observability.response_time_ms\"::FLOAT),0) AS p99_ms FROM {_OBS} WHERE RECORD:\"name\"::STRING='CORTEX_AGENT_REQUEST' AND VALUE:\"snow.ai.observability.response_time_ms\" IS NOT NULL AND {_af(adb,asc,aname,days)}").to_pandas()
        if df.empty: return {}
        r = df.iloc[0]; return {k:_safe_float(r.get(k.upper())) for k in ['avg_ms','p50_ms','p90_ms','p99_ms']}
    except Exception: return {}


@st.cache_data(ttl=60, show_spinner=False)
def get_obs_tokens(_session, adb: str, asc: str, aname: str, days: int) -> Dict:
    try:
        df = _session.sql(f"""WITH rt AS (SELECT TRACE:"trace_id"::STRING AS tid, SUM(TRY_TO_NUMBER(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.total"::STRING)) AS total_tokens, SUM(TRY_TO_NUMBER(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.cache_read_input"::STRING)) AS cache_read, SUM(TRY_TO_NUMBER(RECORD_ATTRIBUTES:"snow.ai.observability.agent.planning.token_count.input"::STRING)) AS input_tokens FROM {_OBS} WHERE RECORD:"name"::STRING LIKE 'ReasoningAgentStepPlanning-%' AND {_af(adb,asc,aname,days)} GROUP BY 1)
        SELECT COUNT(*) AS requests, SUM(total_tokens) AS total, ROUND(AVG(total_tokens),0) AS avg_per_req, ROUND(100.0*SUM(cache_read)/NULLIF(SUM(cache_read)+SUM(input_tokens),0),1) AS cache_hit_pct FROM rt""").to_pandas()
        if df.empty: return {}
        r = df.iloc[0]; return {"requests":_safe_int(r.get("REQUESTS")),"total_tokens":_safe_int(r.get("TOTAL")),"avg_per_request":_safe_int(r.get("AVG_PER_REQ")),"cache_hit_pct":_safe_float(r.get("CACHE_HIT_PCT"))}
    except Exception: return {}


@st.cache_data(ttl=60, show_spinner=False)
def get_obs_quality(_session, adb: str, asc: str, aname: str, days: int) -> Dict:
    try:
        df = _session.sql(f"SELECT COUNT(*) AS total, ROUND(100.0*COUNT(CASE WHEN VALUE:\"snow.ai.observability.response_status_code\"::INT=200 THEN 1 END)/NULLIF(COUNT(*),0),1) AS success_pct, ROUND(100.0*COUNT(CASE WHEN VALUE:\"snow.ai.observability.response_status_code\"::INT>=400 THEN 1 END)/NULLIF(COUNT(*),0),1) AS error_pct FROM {_OBS} WHERE RECORD:\"name\"::STRING='CORTEX_AGENT_REQUEST' AND {_af(adb,asc,aname,days)}").to_pandas()
        if df.empty: return {}
        r = df.iloc[0]; return {"total":_safe_int(r.get("TOTAL")),"success_pct":_safe_float(r.get("SUCCESS_PCT")),"error_pct":_safe_float(r.get("ERROR_PCT"))}
    except Exception: return {}


@st.cache_data(ttl=60, show_spinner=False)
def get_obs_feedback(_session, adb: str, asc: str, aname: str, days: int) -> Dict:
    try:
        df = _session.sql(f"SELECT COUNT(*) AS total, COUNT(CASE WHEN VALUE:\"positive\"::BOOLEAN=TRUE THEN 1 END) AS up, COUNT(CASE WHEN VALUE:\"positive\"::BOOLEAN=FALSE THEN 1 END) AS down FROM {_OBS} WHERE RECORD:\"name\"::STRING='CORTEX_AGENT_FEEDBACK' AND {_af(adb,asc,aname,days)}").to_pandas()
        if df.empty: return {}
        r = df.iloc[0]; return {"total":_safe_int(r.get("TOTAL")),"thumbs_up":_safe_int(r.get("UP")),"thumbs_down":_safe_int(r.get("DOWN"))}
    except Exception: return {}


@st.cache_data(ttl=60, show_spinner=False)
def get_obs_tools(_session, adb: str, asc: str, aname: str, days: int) -> pd.DataFrame:
    try: return _session.sql(f"SELECT n.VALUE::STRING AS TOOL_NAME, COUNT(*) AS INVOCATIONS FROM {_OBS}, LATERAL FLATTEN(input=>PARSE_JSON(RECORD_ATTRIBUTES:\"snow.ai.observability.agent.planning.tool_selection.name\"::STRING)) n WHERE RECORD:\"name\"::STRING LIKE 'ReasoningAgentStepPlanning-%' AND RECORD_ATTRIBUTES:\"snow.ai.observability.agent.planning.tool_selection.name\" IS NOT NULL AND {_af(adb,asc,aname,days)} GROUP BY 1 ORDER BY 2 DESC").to_pandas()
    except Exception: return pd.DataFrame()


@st.cache_data(ttl=60, show_spinner=False)
def get_obs_thread_list(_session, adb: str, asc: str, aname: str, days: int) -> pd.DataFrame:
    try: return _session.sql(f"SELECT RECORD_ATTRIBUTES:\"snow.ai.observability.agent.thread_id\"::STRING AS THREAD_ID, RESOURCE_ATTRIBUTES:\"snow.user.name\"::STRING AS USER_NAME, MIN(TIMESTAMP) AS FIRST_MSG, MAX(TIMESTAMP) AS LAST_MSG, COUNT(*) AS MESSAGES FROM {_OBS} WHERE RECORD:\"name\"::STRING='CORTEX_AGENT_REQUEST' AND RECORD_ATTRIBUTES:\"snow.ai.observability.agent.thread_id\" IS NOT NULL AND {_af(adb,asc,aname,days)} GROUP BY 1,2 ORDER BY MAX(TIMESTAMP) DESC LIMIT 100").to_pandas()
    except Exception: return pd.DataFrame()


def get_obs_thread_conversation(_session, adb: str, asc: str, aname: str, thread_id: str) -> pd.DataFrame:
    db,sc,ag,tid = escape_sql_literal(adb),escape_sql_literal(asc),escape_sql_literal(aname),escape_sql_literal(thread_id)
    try: return _session.sql(f"SELECT TIMESTAMP, RESOURCE_ATTRIBUTES:\"snow.user.name\"::STRING AS USER_NAME, COALESCE(VALUE:\"snow.ai.observability.agent.user_input\"::STRING,VALUE:\"user_input\"::STRING) AS USER_INPUT, COALESCE(VALUE:\"snow.ai.observability.agent.response\"::STRING,VALUE:\"agent_response\"::STRING) AS AGENT_RESPONSE FROM {_OBS} WHERE RECORD:\"name\"::STRING='AgentV2RequestResponseInfo' AND RECORD_ATTRIBUTES:\"snow.ai.observability.database.name\"::STRING='{db}' AND RECORD_ATTRIBUTES:\"snow.ai.observability.schema.name\"::STRING='{sc}' AND RECORD_ATTRIBUTES:\"snow.ai.observability.object.name\"::STRING='{ag}' AND RECORD_ATTRIBUTES:\"snow.ai.observability.agent.thread_id\"::STRING='{tid}' ORDER BY TIMESTAMP ASC").to_pandas()
    except Exception: return pd.DataFrame()
