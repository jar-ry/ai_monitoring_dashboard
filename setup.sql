-- =============================================================================
-- AI MONITORING DASHBOARD - SETUP SCRIPT (V2)
-- =============================================================================
-- Pre-aggregated summary tables for fast dashboard queries.
--
-- Architecture:
--   ACCOUNT_USAGE Views (slow) --> Stored Procedure --> Summary Tables (fast)
--                                        ^
--                                        |
--                                   Snowflake Task (12-hour incremental refresh)
--
-- Refresh modes:
--   CALL REFRESH_AI_USAGE_SUMMARIES(0)    -- Incremental (default, fast)
--   CALL REFRESH_AI_USAGE_SUMMARIES(365)  -- Full refresh (initial load)
--
-- Source views covered:
--   GA:      CORTEX_AISQL (w/ input/output tokens), CORTEX_FUNCTIONS (deprecated),
--            CORTEX_ANALYST, CORTEX_SEARCH_DAILY, CORTEX_FINE_TUNING,
--            CORTEX_DOCUMENT_PROCESSING, CORTEX_REST_API (w/ input/output tokens),
--            CORTEX_CODE_CLI, CORTEX_CODE_SNOWSIGHT,
--            CORTEX_PROVISIONED_THROUGHPUT,
--            CORTEX_AGENT, SNOWFLAKE_INTELLIGENCE (wrapped in TRY/CATCH)
--
-- Reconciliation: Compare summary totals against METERING_DAILY_HISTORY
--   with SERVICE_TYPE='AI_SERVICES' for validation.
--
-- NOT TRACKABLE (Snowflake platform limits):
--   - ML Functions (FORECAST, ANOMALY_DETECTION, etc.) - use warehouse compute
--   - Streamlit AI attribution by app name - not in usage views
--   - Per-call error rates, concurrency, queue time - not in usage views
-- =============================================================================

-- Configuration - Update these values to match your environment
SET DB_NAME = 'SAMPLES_DB';
SET SCHEMA_NAME = 'PUBLIC';
SET WAREHOUSE_NAME = 'COMPUTE_WH';
SET TASK_TIMEZONE = 'America/Los_Angeles';

USE DATABASE IDENTIFIER($DB_NAME);
USE SCHEMA IDENTIFIER($SCHEMA_NAME);

-- =============================================================================
-- STEP 1: CREATE SUMMARY TABLES
-- =============================================================================
-- No NOT NULL or PK constraints on data columns - ACCOUNT_USAGE may return NULLs.
-- INPUT_TOKENS / OUTPUT_TOKENS parsed from TOKENS_GRANULAR (AISQL + REST API).

CREATE OR REPLACE TABLE AI_USAGE_DAILY_SUMMARY (
    USAGE_DATE          DATE,
    FEATURE_NAME        VARCHAR(100),
    CATEGORY            VARCHAR(50),
    MODEL_NAME          VARCHAR(100),
    TOTAL_CREDITS       FLOAT DEFAULT 0,
    TOTAL_TOKENS        NUMBER DEFAULT 0,
    INPUT_TOKENS        NUMBER DEFAULT 0,
    OUTPUT_TOKENS       NUMBER DEFAULT 0,
    TOTAL_CALLS         NUMBER DEFAULT 0,
    UNIQUE_USERS        NUMBER DEFAULT 0,
    LAST_REFRESHED      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE AI_USAGE_USER_SUMMARY (
    USAGE_DATE          DATE,
    USER_NAME           VARCHAR(256),
    FEATURE_NAME        VARCHAR(100),
    CATEGORY            VARCHAR(50),
    TOTAL_CREDITS       FLOAT DEFAULT 0,
    TOTAL_TOKENS        NUMBER DEFAULT 0,
    INPUT_TOKENS        NUMBER DEFAULT 0,
    OUTPUT_TOKENS       NUMBER DEFAULT 0,
    TOTAL_CALLS         NUMBER DEFAULT 0,
    LAST_REFRESHED      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE AI_USAGE_MODEL_SUMMARY (
    USAGE_DATE          DATE,
    MODEL_NAME          VARCHAR(100),
    TOTAL_CREDITS       FLOAT DEFAULT 0,
    TOTAL_TOKENS        NUMBER DEFAULT 0,
    INPUT_TOKENS        NUMBER DEFAULT 0,
    OUTPUT_TOKENS       NUMBER DEFAULT 0,
    TOTAL_CALLS         NUMBER DEFAULT 0,
    LAST_REFRESHED      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE AI_USAGE_REFRESH_LOG (
    REFRESH_ID          NUMBER AUTOINCREMENT,
    REFRESH_START       TIMESTAMP_NTZ,
    REFRESH_END         TIMESTAMP_NTZ,
    REFRESH_MODE        VARCHAR(20),       -- 'FULL' or 'INCREMENTAL'
    INCREMENTAL_FROM    DATE,              -- Start date used for this refresh
    ROWS_DAILY          NUMBER,
    ROWS_USER           NUMBER,
    ROWS_MODEL          NUMBER,
    STATUS              VARCHAR(20),       -- 'RUNNING', 'SUCCESS', 'PARTIAL', 'FAILED'
    ERROR_MESSAGE       VARCHAR(4000),
    SOURCE_ERRORS       VARCHAR(4000)
);

CREATE OR REPLACE TABLE AI_USAGE_BUDGETS (
    BUDGET_ID           NUMBER AUTOINCREMENT,
    BUDGET_NAME         VARCHAR(100) NOT NULL,
    BUDGET_PERIOD       VARCHAR(20) NOT NULL,
    FEATURE_NAME        VARCHAR(100),          -- NULL = all features; set for per-feature budget
    BUDGET_CREDITS      FLOAT NOT NULL,
    ALERT_THRESHOLD_PCT FLOAT DEFAULT 80,
    IS_ACTIVE           BOOLEAN DEFAULT TRUE,
    CREATED_BY          VARCHAR(256),
    CREATED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UNIQUE (BUDGET_NAME)
);

CREATE OR REPLACE TABLE AI_USAGE_USER_THRESHOLDS (
    THRESHOLD_ID        NUMBER AUTOINCREMENT,
    USER_NAME           VARCHAR(256),
    FEATURE_NAME        VARCHAR(100),
    MAX_DAILY_CREDITS   FLOAT,
    MAX_DAILY_CALLS     NUMBER,
    MULTIPLIER_ALERT    FLOAT DEFAULT 3,
    IS_ACTIVE           BOOLEAN DEFAULT TRUE,
    CREATED_BY          VARCHAR(256),
    CREATED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Insert default budget
INSERT INTO AI_USAGE_BUDGETS (BUDGET_NAME, BUDGET_PERIOD, FEATURE_NAME, BUDGET_CREDITS, ALERT_THRESHOLD_PCT, CREATED_BY)
VALUES ('Default Monthly Budget', 'MONTHLY', NULL, 1000, 80, CURRENT_USER());

-- Insert default threshold for anomaly detection
INSERT INTO AI_USAGE_USER_THRESHOLDS (USER_NAME, FEATURE_NAME, MAX_DAILY_CREDITS, MULTIPLIER_ALERT, CREATED_BY)
VALUES (NULL, NULL, 100, 3, CURRENT_USER());

-- =============================================================================
-- STEP 2: CREATE REFRESH STORED PROCEDURE
-- =============================================================================
-- DAYS_TO_REFRESH = 0  : Incremental (from last success - 3 day overlap). DEFAULT.
-- DAYS_TO_REFRESH > 0  : Full refresh for N days (use 365 for initial load).
--
-- Each source INSERT wrapped in TRY/CATCH so one failing view won't block all.
-- Status: 'SUCCESS' (all OK), 'PARTIAL' (some failed), 'FAILED' (fatal error).
-- Data retention: Deletes summary data older than 400 days each run.

CREATE OR REPLACE PROCEDURE REFRESH_AI_USAGE_SUMMARIES(DAYS_TO_REFRESH NUMBER DEFAULT 0)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Refreshes AI usage summary tables. 0=incremental (default), >0=full refresh for N days.'
AS
$$
DECLARE
    v_start_date DATE;
    v_end_date DATE;
    v_refresh_start TIMESTAMP_NTZ;
    v_last_refresh DATE;
    v_rows_daily NUMBER := 0;
    v_rows_user NUMBER := 0;
    v_rows_model NUMBER := 0;
    v_source_errors VARCHAR := '';
    v_refresh_mode VARCHAR := 'FULL';
    v_has_aisql BOOLEAN := FALSE;
    v_error_msg VARCHAR;
BEGIN
    v_refresh_start := CURRENT_TIMESTAMP();
    v_end_date := CURRENT_DATE();

    -- =========================================================================
    -- DETERMINE REFRESH WINDOW
    -- =========================================================================
    IF (DAYS_TO_REFRESH = 0) THEN
        BEGIN
            SELECT MAX(REFRESH_END)::DATE INTO v_last_refresh
            FROM AI_USAGE_REFRESH_LOG
            WHERE STATUS IN ('SUCCESS', 'PARTIAL');
        EXCEPTION WHEN OTHER THEN
            v_last_refresh := NULL;
        END;

        IF (v_last_refresh IS NOT NULL) THEN
            v_start_date := DATEADD(day, -3, v_last_refresh);
            v_refresh_mode := 'INCREMENTAL';
        ELSE
            v_start_date := DATEADD(day, -90, v_end_date);
            v_refresh_mode := 'FULL';
        END IF;
    ELSE
        v_start_date := DATEADD(day, -DAYS_TO_REFRESH, v_end_date);
        v_refresh_mode := 'FULL';
    END IF;

    -- Log start
    INSERT INTO AI_USAGE_REFRESH_LOG (REFRESH_START, REFRESH_MODE, INCREMENTAL_FROM, STATUS)
    VALUES (:v_refresh_start, :v_refresh_mode, :v_start_date, 'RUNNING');

    BEGIN
        -- =================================================================
        -- DATA RETENTION: Delete data older than 400 days
        -- =================================================================
        DELETE FROM AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE < DATEADD(day, -400, CURRENT_DATE());
        DELETE FROM AI_USAGE_USER_SUMMARY WHERE USAGE_DATE < DATEADD(day, -400, CURRENT_DATE());
        DELETE FROM AI_USAGE_MODEL_SUMMARY WHERE USAGE_DATE < DATEADD(day, -400, CURRENT_DATE());

        -- =================================================================
        -- DELETE EXISTING DATA FOR REFRESH WINDOW
        -- =================================================================
        DELETE FROM AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE >= :v_start_date;
        DELETE FROM AI_USAGE_USER_SUMMARY WHERE USAGE_DATE >= :v_start_date;
        DELETE FROM AI_USAGE_MODEL_SUMMARY WHERE USAGE_DATE >= :v_start_date;

        -- =================================================================
        -- DAILY SUMMARY INSERTS
        -- =================================================================

        -- 1. Cortex Functions (AISQL) - GA Dec 2025
        --    Try with TOKENS_GRANULAR; fall back without if column not available
        --    Sets v_has_aisql flag so deprecated view can adapt its date range
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(USAGE_TIME),
                COALESCE(FUNCTION_NAME, 'CORTEX_FUNCTION'),
                'Cortex Functions',
                COALESCE(MODEL_NAME, 'N/A'),
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(TOKENS_GRANULAR:input::VARCHAR)), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(TOKENS_GRANULAR:output::VARCHAR)), 0)::NUMBER,
                COUNT(*),
                COUNT(DISTINCT USER_ID),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AISQL_USAGE_HISTORY
            WHERE USAGE_TIME >= :v_start_date AND USAGE_TIME IS NOT NULL
            GROUP BY DATE(USAGE_TIME), COALESCE(FUNCTION_NAME, 'CORTEX_FUNCTION'), COALESCE(MODEL_NAME, 'N/A');
            v_has_aisql := TRUE;
        EXCEPTION WHEN OTHER THEN
            -- TOKENS_GRANULAR may not exist; retry without it
            BEGIN
                INSERT INTO AI_USAGE_DAILY_SUMMARY
                    (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
                SELECT
                    DATE(USAGE_TIME),
                    COALESCE(FUNCTION_NAME, 'CORTEX_FUNCTION'),
                    'Cortex Functions',
                    COALESCE(MODEL_NAME, 'N/A'),
                    COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                    COALESCE(SUM(TOKENS), 0)::NUMBER,
                    0, 0,
                    COUNT(*),
                    COUNT(DISTINCT USER_ID),
                    CURRENT_TIMESTAMP()
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AISQL_USAGE_HISTORY
                WHERE USAGE_TIME >= :v_start_date AND USAGE_TIME IS NOT NULL
                GROUP BY DATE(USAGE_TIME), COALESCE(FUNCTION_NAME, 'CORTEX_FUNCTION'), COALESCE(MODEL_NAME, 'N/A');
                v_has_aisql := TRUE;
            EXCEPTION WHEN OTHER THEN
                v_source_errors := v_source_errors || 'AISQL_DAILY: ' || SQLERRM || '; ';
            END;
        END;

        -- 2. Cortex Functions (DEPRECATED view)
        --    If AISQL exists: load only pre-Nov 2025 data (avoid double-counting)
        --    If AISQL does NOT exist: load ALL data (this is the only source)
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                COALESCE(FUNCTION_NAME, 'CORTEX_FUNCTION'),
                'Cortex Functions',
                COALESCE(MODEL_NAME, 'N/A'),
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                COUNT(DISTINCT WAREHOUSE_ID),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
                AND (:v_has_aisql = FALSE OR START_TIME < '2025-11-17')
            GROUP BY DATE(START_TIME), COALESCE(FUNCTION_NAME, 'CORTEX_FUNCTION'), COALESCE(MODEL_NAME, 'N/A');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'CORTEX_FUNC_DAILY: ' || SQLERRM || '; ';
        END;

        -- 3. Cortex Analyst - GA
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                'CORTEX_ANALYST',
                'Cortex Analyst',
                'N/A',
                COALESCE(SUM(CREDITS), 0)::FLOAT,
                0, 0, 0,
                COALESCE(SUM(REQUEST_COUNT), 0)::NUMBER,
                COUNT(DISTINCT USERNAME),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
            GROUP BY DATE(START_TIME);
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'ANALYST_DAILY: ' || SQLERRM || '; ';
        END;

        -- 4. Cortex Search (DAILY view - serving + embed query credits)
        --    Split by CONSUMPTION_TYPE. TOKENS is VARCHAR - use TRY_CAST.
        --    NOTE: Do NOT also use CORTEX_SEARCH_SERVING - that would double count.
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(USAGE_DATE),
                CASE CONSUMPTION_TYPE
                    WHEN 'SERVING' THEN 'CORTEX_SEARCH_SERVING'
                    ELSE 'CORTEX_SEARCH_QUERY'
                END,
                'Cortex Search',
                COALESCE(MODEL_NAME, 'N/A'),
                COALESCE(SUM(CREDITS), 0)::FLOAT,
                COALESCE(SUM(TRY_CAST(TOKENS AS NUMBER)), 0)::NUMBER,
                0, 0,
                COUNT(*),
                COUNT(DISTINCT SERVICE_NAME),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
            WHERE USAGE_DATE >= :v_start_date AND USAGE_DATE IS NOT NULL
            GROUP BY DATE(USAGE_DATE),
                CASE CONSUMPTION_TYPE WHEN 'SERVING' THEN 'CORTEX_SEARCH_SERVING' ELSE 'CORTEX_SEARCH_QUERY' END,
                COALESCE(MODEL_NAME, 'N/A');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'SEARCH_DAILY: ' || SQLERRM || '; ';
        END;

        -- 5. Cortex Fine-tuning - GA Oct 2024
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                'CORTEX_FINE_TUNING',
                'Cortex Fine-tuning',
                COALESCE(MODEL_NAME, 'N/A'),
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                COUNT(DISTINCT MODEL_NAME),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FINE_TUNING_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
            GROUP BY DATE(START_TIME), COALESCE(MODEL_NAME, 'N/A');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'FINE_TUNING_DAILY: ' || SQLERRM || '; ';
        END;

        -- 6. Document AI / AI Extract - GA
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                COALESCE(FUNCTION_NAME, 'AI_EXTRACT'),
                'Document AI',
                COALESCE(MODEL_NAME, 'N/A'),
                COALESCE(SUM(CREDITS_USED), 0)::FLOAT,
                0, 0, 0,
                COUNT(*),
                COUNT(DISTINCT QUERY_ID),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
            GROUP BY DATE(START_TIME), COALESCE(FUNCTION_NAME, 'AI_EXTRACT'), COALESCE(MODEL_NAME, 'N/A');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'DOC_AI_DAILY: ' || SQLERRM || '; ';
        END;

        -- 7. Cortex REST API - GA
        --    Try with TOKENS_GRANULAR; fall back without if column not available
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                'REST_API',
                'Cortex REST API',
                COALESCE(MODEL_NAME, 'N/A'),
                0::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(TOKENS_GRANULAR:input::VARCHAR)), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(TOKENS_GRANULAR:output::VARCHAR)), 0)::NUMBER,
                COUNT(*),
                COUNT(DISTINCT USER_ID),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
            GROUP BY DATE(START_TIME), COALESCE(MODEL_NAME, 'N/A');
        EXCEPTION WHEN OTHER THEN
            BEGIN
                INSERT INTO AI_USAGE_DAILY_SUMMARY
                    (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
                SELECT
                    DATE(START_TIME),
                    'REST_API',
                    'Cortex REST API',
                    COALESCE(MODEL_NAME, 'N/A'),
                    0::FLOAT,
                    COALESCE(SUM(TOKENS), 0)::NUMBER,
                    0, 0,
                    COUNT(*),
                    COUNT(DISTINCT USER_ID),
                    CURRENT_TIMESTAMP()
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY
                WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
                GROUP BY DATE(START_TIME), COALESCE(MODEL_NAME, 'N/A');
            EXCEPTION WHEN OTHER THEN
                v_source_errors := v_source_errors || 'REST_API_DAILY: ' || SQLERRM || '; ';
            END;
        END;

        -- 8. Cortex Agents - GA
        --    Uses native START_TIME and USER_NAME columns (updated schema)
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                'CORTEX_AGENT',
                'Cortex Agents',
                COALESCE(AGENT_NAME, 'N/A'),
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                COUNT(DISTINCT USER_ID),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
            GROUP BY DATE(START_TIME), COALESCE(AGENT_NAME, 'N/A');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'AGENT_DAILY: ' || SQLERRM || '; ';
        END;

        -- 9. Snowflake Intelligence
        --    Uses native START_TIME, USER_NAME, SNOWFLAKE_INTELLIGENCE_NAME columns
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                'SNOWFLAKE_INTELLIGENCE',
                'Snowflake Intelligence',
                COALESCE(SNOWFLAKE_INTELLIGENCE_NAME, 'N/A'),
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                COUNT(DISTINCT USER_ID),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
            GROUP BY DATE(START_TIME), COALESCE(SNOWFLAKE_INTELLIGENCE_NAME, 'N/A');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'INTELLIGENCE_DAILY: ' || SQLERRM || '; ';
        END;

        -- 10. Cortex Code CLI
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(USAGE_TIME),
                'CORTEX_CODE_CLI',
                'Cortex Code',
                'N/A',
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                COUNT(DISTINCT USER_ID),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY
            WHERE USAGE_TIME >= :v_start_date AND USAGE_TIME IS NOT NULL
            GROUP BY DATE(USAGE_TIME);
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'CODE_CLI_DAILY: ' || SQLERRM || '; ';
        END;

        -- 11. Cortex Code Snowsight
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(USAGE_TIME),
                'CORTEX_CODE_SNOWSIGHT',
                'Cortex Code',
                'N/A',
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                COUNT(DISTINCT USER_ID),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY
            WHERE USAGE_TIME >= :v_start_date AND USAGE_TIME IS NOT NULL
            GROUP BY DATE(USAGE_TIME);
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'CODE_SNOWSIGHT_DAILY: ' || SQLERRM || '; ';
        END;

        -- 12. Cortex Provisioned Throughput
        --    PTU billing - TOTAL_CALLS stores PTU_COUNT, no user or token attribution
        BEGIN
            INSERT INTO AI_USAGE_DAILY_SUMMARY
                (USAGE_DATE, FEATURE_NAME, CATEGORY, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, UNIQUE_USERS, LAST_REFRESHED)
            SELECT
                DATE(INTERVAL_START_TIME),
                'PROVISIONED_THROUGHPUT',
                'Provisioned Throughput',
                COALESCE(MODEL_NAME, 'N/A'),
                COALESCE(SUM(PTU_CREDITS), 0)::FLOAT,
                0, 0, 0,
                COALESCE(SUM(PTU_COUNT), 0)::NUMBER,
                0,
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY
            WHERE INTERVAL_START_TIME >= :v_start_date AND INTERVAL_START_TIME IS NOT NULL
            GROUP BY DATE(INTERVAL_START_TIME), COALESCE(MODEL_NAME, 'N/A');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'PTU_DAILY: ' || SQLERRM || '; ';
        END;

        SELECT COUNT(*) INTO :v_rows_daily FROM AI_USAGE_DAILY_SUMMARY WHERE USAGE_DATE >= :v_start_date;

        -- =================================================================
        -- USER SUMMARY INSERTS
        -- =================================================================

        -- 1. Cortex Functions by user - AISQL (GA)
        --    Try with TOKENS_GRANULAR; fall back without if column not available
        BEGIN
            INSERT INTO AI_USAGE_USER_SUMMARY
                (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(c.USAGE_TIME),
                COALESCE(u.NAME, CAST(c.USER_ID AS VARCHAR), 'UNKNOWN'),
                COALESCE(c.FUNCTION_NAME, 'CORTEX_FUNCTION'),
                'Cortex Functions',
                COALESCE(SUM(c.TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(c.TOKENS), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(c.TOKENS_GRANULAR:input::VARCHAR)), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(c.TOKENS_GRANULAR:output::VARCHAR)), 0)::NUMBER,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AISQL_USAGE_HISTORY c
            LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON c.USER_ID = u.USER_ID
            WHERE c.USAGE_TIME >= :v_start_date AND c.USAGE_TIME IS NOT NULL AND c.USER_ID IS NOT NULL
            GROUP BY DATE(c.USAGE_TIME), COALESCE(u.NAME, CAST(c.USER_ID AS VARCHAR), 'UNKNOWN'), COALESCE(c.FUNCTION_NAME, 'CORTEX_FUNCTION');
        EXCEPTION WHEN OTHER THEN
            BEGIN
                INSERT INTO AI_USAGE_USER_SUMMARY
                    (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
                SELECT
                    DATE(c.USAGE_TIME),
                    COALESCE(u.NAME, CAST(c.USER_ID AS VARCHAR), 'UNKNOWN'),
                    COALESCE(c.FUNCTION_NAME, 'CORTEX_FUNCTION'),
                    'Cortex Functions',
                    COALESCE(SUM(c.TOKEN_CREDITS), 0)::FLOAT,
                    COALESCE(SUM(c.TOKENS), 0)::NUMBER,
                    0, 0,
                    COUNT(*),
                    CURRENT_TIMESTAMP()
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AISQL_USAGE_HISTORY c
                LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON c.USER_ID = u.USER_ID
                WHERE c.USAGE_TIME >= :v_start_date AND c.USAGE_TIME IS NOT NULL AND c.USER_ID IS NOT NULL
                GROUP BY DATE(c.USAGE_TIME), COALESCE(u.NAME, CAST(c.USER_ID AS VARCHAR), 'UNKNOWN'), COALESCE(c.FUNCTION_NAME, 'CORTEX_FUNCTION');
            EXCEPTION WHEN OTHER THEN
                v_source_errors := v_source_errors || 'AISQL_USER: ' || SQLERRM || '; ';
            END;
        END;

        -- 2. Cortex Functions by user - DEPRECATED view
        --    If AISQL exists: load only pre-Nov 2025 data; otherwise load ALL
        BEGIN
            INSERT INTO AI_USAGE_USER_SUMMARY
                (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                COALESCE(CAST(WAREHOUSE_ID AS VARCHAR), 'UNKNOWN'),
                COALESCE(FUNCTION_NAME, 'CORTEX_FUNCTION'),
                'Cortex Functions',
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
                AND (:v_has_aisql = FALSE OR START_TIME < '2025-11-17')
            GROUP BY DATE(START_TIME), COALESCE(CAST(WAREHOUSE_ID AS VARCHAR), 'UNKNOWN'), COALESCE(FUNCTION_NAME, 'CORTEX_FUNCTION');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'CORTEX_FUNC_USER: ' || SQLERRM || '; ';
        END;

        -- 3. Cortex Analyst by user - GA
        BEGIN
            INSERT INTO AI_USAGE_USER_SUMMARY
                (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                COALESCE(CAST(USERNAME AS VARCHAR), 'UNKNOWN'),
                'CORTEX_ANALYST',
                'Cortex Analyst',
                COALESCE(SUM(CREDITS), 0)::FLOAT,
                0, 0, 0,
                COALESCE(SUM(REQUEST_COUNT), 0)::NUMBER,
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL AND USERNAME IS NOT NULL
            GROUP BY DATE(START_TIME), COALESCE(CAST(USERNAME AS VARCHAR), 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'ANALYST_USER: ' || SQLERRM || '; ';
        END;

        -- 4. Cortex REST API by user - GA (0 credits)
        --    Try with TOKENS_GRANULAR; fall back without if column not available
        BEGIN
            INSERT INTO AI_USAGE_USER_SUMMARY
                (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(r.START_TIME),
                COALESCE(u.NAME, CAST(r.USER_ID AS VARCHAR), 'UNKNOWN'),
                'REST_API',
                'Cortex REST API',
                0::FLOAT,
                COALESCE(SUM(r.TOKENS), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(r.TOKENS_GRANULAR:input::VARCHAR)), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(r.TOKENS_GRANULAR:output::VARCHAR)), 0)::NUMBER,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY r
            LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON TRY_CAST(r.USER_ID AS NUMBER) = u.USER_ID
            WHERE r.START_TIME >= :v_start_date AND r.START_TIME IS NOT NULL AND r.USER_ID IS NOT NULL
            GROUP BY DATE(r.START_TIME), COALESCE(u.NAME, CAST(r.USER_ID AS VARCHAR), 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            BEGIN
                INSERT INTO AI_USAGE_USER_SUMMARY
                    (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
                SELECT
                    DATE(r.START_TIME),
                    COALESCE(u.NAME, CAST(r.USER_ID AS VARCHAR), 'UNKNOWN'),
                    'REST_API',
                    'Cortex REST API',
                    0::FLOAT,
                    COALESCE(SUM(r.TOKENS), 0)::NUMBER,
                    0, 0,
                    COUNT(*),
                    CURRENT_TIMESTAMP()
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY r
                LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON TRY_CAST(r.USER_ID AS NUMBER) = u.USER_ID
                WHERE r.START_TIME >= :v_start_date AND r.START_TIME IS NOT NULL AND r.USER_ID IS NOT NULL
                GROUP BY DATE(r.START_TIME), COALESCE(u.NAME, CAST(r.USER_ID AS VARCHAR), 'UNKNOWN');
            EXCEPTION WHEN OTHER THEN
                v_source_errors := v_source_errors || 'REST_API_USER: ' || SQLERRM || '; ';
            END;
        END;

        -- 5. Cortex Agents by user - GA
        --    Uses native START_TIME and USER_NAME columns (updated schema)
        BEGIN
            INSERT INTO AI_USAGE_USER_SUMMARY
                (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                COALESCE(USER_NAME, CAST(USER_ID AS VARCHAR), 'UNKNOWN'),
                'CORTEX_AGENT',
                'Cortex Agents',
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL AND USER_ID IS NOT NULL
            GROUP BY DATE(START_TIME), COALESCE(USER_NAME, CAST(USER_ID AS VARCHAR), 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'AGENT_USER: ' || SQLERRM || '; ';
        END;

        -- 6. Snowflake Intelligence by user
        --    Uses native START_TIME and USER_NAME columns (updated schema)
        BEGIN
            INSERT INTO AI_USAGE_USER_SUMMARY
                (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                COALESCE(USER_NAME, CAST(USER_ID AS VARCHAR), 'UNKNOWN'),
                'SNOWFLAKE_INTELLIGENCE',
                'Snowflake Intelligence',
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL AND USER_ID IS NOT NULL
            GROUP BY DATE(START_TIME), COALESCE(USER_NAME, CAST(USER_ID AS VARCHAR), 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'INTELLIGENCE_USER: ' || SQLERRM || '; ';
        END;

        -- 7. Cortex Code CLI by user
        BEGIN
            INSERT INTO AI_USAGE_USER_SUMMARY
                (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(c.USAGE_TIME),
                COALESCE(u.NAME, CAST(c.USER_ID AS VARCHAR), 'UNKNOWN'),
                'CORTEX_CODE_CLI',
                'Cortex Code',
                COALESCE(SUM(c.TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(c.TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY c
            LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON c.USER_ID = u.USER_ID
            WHERE c.USAGE_TIME >= :v_start_date AND c.USAGE_TIME IS NOT NULL AND c.USER_ID IS NOT NULL
            GROUP BY DATE(c.USAGE_TIME), COALESCE(u.NAME, CAST(c.USER_ID AS VARCHAR), 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'CODE_CLI_USER: ' || SQLERRM || '; ';
        END;

        -- 8. Cortex Code Snowsight by user
        BEGIN
            INSERT INTO AI_USAGE_USER_SUMMARY
                (USAGE_DATE, USER_NAME, FEATURE_NAME, CATEGORY, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(c.USAGE_TIME),
                COALESCE(u.NAME, CAST(c.USER_ID AS VARCHAR), 'UNKNOWN'),
                'CORTEX_CODE_SNOWSIGHT',
                'Cortex Code',
                COALESCE(SUM(c.TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(c.TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY c
            LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON c.USER_ID = u.USER_ID
            WHERE c.USAGE_TIME >= :v_start_date AND c.USAGE_TIME IS NOT NULL AND c.USER_ID IS NOT NULL
            GROUP BY DATE(c.USAGE_TIME), COALESCE(u.NAME, CAST(c.USER_ID AS VARCHAR), 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'CODE_SNOWSIGHT_USER: ' || SQLERRM || '; ';
        END;

        SELECT COUNT(*) INTO :v_rows_user FROM AI_USAGE_USER_SUMMARY WHERE USAGE_DATE >= :v_start_date;

        -- =================================================================
        -- MODEL SUMMARY INSERTS
        -- =================================================================

        -- 1. Models from AISQL (GA)
        --    Try with TOKENS_GRANULAR; fall back without if column not available
        BEGIN
            INSERT INTO AI_USAGE_MODEL_SUMMARY
                (USAGE_DATE, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(USAGE_TIME),
                COALESCE(MODEL_NAME, 'UNKNOWN'),
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(TOKENS_GRANULAR:input::VARCHAR)), 0)::NUMBER,
                COALESCE(SUM(TRY_TO_NUMBER(TOKENS_GRANULAR:output::VARCHAR)), 0)::NUMBER,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AISQL_USAGE_HISTORY
            WHERE USAGE_TIME >= :v_start_date AND USAGE_TIME IS NOT NULL
                AND MODEL_NAME IS NOT NULL AND MODEL_NAME != ''
            GROUP BY DATE(USAGE_TIME), COALESCE(MODEL_NAME, 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            BEGIN
                INSERT INTO AI_USAGE_MODEL_SUMMARY
                    (USAGE_DATE, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
                SELECT
                    DATE(USAGE_TIME),
                    COALESCE(MODEL_NAME, 'UNKNOWN'),
                    COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                    COALESCE(SUM(TOKENS), 0)::NUMBER,
                    0, 0,
                    COUNT(*),
                    CURRENT_TIMESTAMP()
                FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AISQL_USAGE_HISTORY
                WHERE USAGE_TIME >= :v_start_date AND USAGE_TIME IS NOT NULL
                    AND MODEL_NAME IS NOT NULL AND MODEL_NAME != ''
                GROUP BY DATE(USAGE_TIME), COALESCE(MODEL_NAME, 'UNKNOWN');
            EXCEPTION WHEN OTHER THEN
                v_source_errors := v_source_errors || 'AISQL_MODEL: ' || SQLERRM || '; ';
            END;
        END;

        -- 2. Models from deprecated view
        --    If AISQL exists: load only pre-Nov 2025 data; otherwise load ALL
        BEGIN
            INSERT INTO AI_USAGE_MODEL_SUMMARY
                (USAGE_DATE, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(START_TIME),
                COALESCE(MODEL_NAME, 'UNKNOWN'),
                COALESCE(SUM(TOKEN_CREDITS), 0)::FLOAT,
                COALESCE(SUM(TOKENS), 0)::NUMBER,
                0, 0,
                COUNT(*),
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
            WHERE START_TIME >= :v_start_date AND START_TIME IS NOT NULL
                AND (:v_has_aisql = FALSE OR START_TIME < '2025-11-17')
                AND MODEL_NAME IS NOT NULL AND MODEL_NAME != ''
            GROUP BY DATE(START_TIME), COALESCE(MODEL_NAME, 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'CORTEX_FUNC_MODEL: ' || SQLERRM || '; ';
        END;

        -- 3. Provisioned Throughput by model
        BEGIN
            INSERT INTO AI_USAGE_MODEL_SUMMARY
                (USAGE_DATE, MODEL_NAME, TOTAL_CREDITS, TOTAL_TOKENS, INPUT_TOKENS, OUTPUT_TOKENS, TOTAL_CALLS, LAST_REFRESHED)
            SELECT
                DATE(INTERVAL_START_TIME),
                COALESCE(MODEL_NAME, 'UNKNOWN'),
                COALESCE(SUM(PTU_CREDITS), 0)::FLOAT,
                0, 0, 0,
                COALESCE(SUM(PTU_COUNT), 0)::NUMBER,
                CURRENT_TIMESTAMP()
            FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY
            WHERE INTERVAL_START_TIME >= :v_start_date AND INTERVAL_START_TIME IS NOT NULL
                AND MODEL_NAME IS NOT NULL AND MODEL_NAME != ''
            GROUP BY DATE(INTERVAL_START_TIME), COALESCE(MODEL_NAME, 'UNKNOWN');
        EXCEPTION WHEN OTHER THEN
            v_source_errors := v_source_errors || 'PTU_MODEL: ' || SQLERRM || '; ';
        END;

        SELECT COUNT(*) INTO :v_rows_model FROM AI_USAGE_MODEL_SUMMARY WHERE USAGE_DATE >= :v_start_date;

        -- =================================================================
        -- LOG COMPLETION
        -- =================================================================
        IF (v_source_errors = '') THEN
            UPDATE AI_USAGE_REFRESH_LOG
            SET REFRESH_END = CURRENT_TIMESTAMP(),
                ROWS_DAILY = :v_rows_daily, ROWS_USER = :v_rows_user, ROWS_MODEL = :v_rows_model,
                STATUS = 'SUCCESS'
            WHERE REFRESH_START = :v_refresh_start;
        ELSE
            UPDATE AI_USAGE_REFRESH_LOG
            SET REFRESH_END = CURRENT_TIMESTAMP(),
                ROWS_DAILY = :v_rows_daily, ROWS_USER = :v_rows_user, ROWS_MODEL = :v_rows_model,
                STATUS = 'PARTIAL',
                SOURCE_ERRORS = :v_source_errors
            WHERE REFRESH_START = :v_refresh_start;
        END IF;

        RETURN OBJECT_CONSTRUCT(
            'status', CASE WHEN v_source_errors = '' THEN 'SUCCESS' ELSE 'PARTIAL' END,
            'refresh_mode', v_refresh_mode,
            'start_date', v_start_date,
            'end_date', v_end_date,
            'rows_daily', v_rows_daily,
            'rows_user', v_rows_user,
            'rows_model', v_rows_model,
            'source_errors', CASE WHEN v_source_errors != '' THEN v_source_errors ELSE NULL END,
            'refresh_start', v_refresh_start,
            'refresh_end', CURRENT_TIMESTAMP()
        );

    EXCEPTION
        WHEN OTHER THEN
            v_error_msg := SQLERRM;
            UPDATE AI_USAGE_REFRESH_LOG
            SET REFRESH_END = CURRENT_TIMESTAMP(),
                STATUS = 'FAILED',
                ERROR_MESSAGE = :v_error_msg
            WHERE REFRESH_START = :v_refresh_start;

            RETURN OBJECT_CONSTRUCT(
                'status', 'FAILED',
                'error', v_error_msg
            );
    END;
END;
$$;

-- =============================================================================
-- STEP 3: CREATE SCHEDULED TASK (12-HOUR INCREMENTAL REFRESH)
-- =============================================================================

CREATE OR REPLACE TASK REFRESH_AI_USAGE_TASK
    WAREHOUSE = IDENTIFIER($WAREHOUSE_NAME)
    SCHEDULE = 'USING CRON 0 0,12 * * * America/Los_Angeles'
    COMMENT = 'Twice-daily incremental refresh of AI usage summary tables'
AS
    CALL REFRESH_AI_USAGE_SUMMARIES(0);  -- 0 = incremental

-- =============================================================================
-- STEP 4: INITIAL DATA LOAD (full 365-day backfill)
-- =============================================================================

CALL REFRESH_AI_USAGE_SUMMARIES(365);

-- =============================================================================
-- STEP 5: ENABLE THE TASK
-- =============================================================================

ALTER TASK REFRESH_AI_USAGE_TASK RESUME;

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================

-- Row counts
SELECT 'AI_USAGE_DAILY_SUMMARY' as TBL, COUNT(*) as ROWS FROM AI_USAGE_DAILY_SUMMARY
UNION ALL SELECT 'AI_USAGE_USER_SUMMARY', COUNT(*) FROM AI_USAGE_USER_SUMMARY
UNION ALL SELECT 'AI_USAGE_MODEL_SUMMARY', COUNT(*) FROM AI_USAGE_MODEL_SUMMARY;

-- Last refresh status
SELECT REFRESH_MODE, INCREMENTAL_FROM, STATUS, SOURCE_ERRORS, ROWS_DAILY, ROWS_USER, ROWS_MODEL,
       DATEDIFF(second, REFRESH_START, REFRESH_END) as DURATION_SEC
FROM AI_USAGE_REFRESH_LOG ORDER BY REFRESH_START DESC LIMIT 5;

-- Data reconciliation: compare summary totals vs METERING_DAILY_HISTORY
SELECT
    'SUMMARY_TABLES' as SOURCE,
    SUM(TOTAL_CREDITS) as TOTAL_CREDITS
FROM AI_USAGE_DAILY_SUMMARY
WHERE USAGE_DATE >= DATEADD(day, -30, CURRENT_DATE())
UNION ALL
SELECT
    'METERING_DAILY_HISTORY' as SOURCE,
    SUM(CREDITS_USED) as TOTAL_CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE SERVICE_TYPE = 'AI_SERVICES'
    AND USAGE_DATE >= DATEADD(day, -30, CURRENT_DATE());

-- Input vs output token breakdown by model (last 30 days)
SELECT MODEL_NAME,
    SUM(TOTAL_TOKENS) as TOTAL_TOKENS,
    SUM(INPUT_TOKENS) as INPUT_TOKENS,
    SUM(OUTPUT_TOKENS) as OUTPUT_TOKENS,
    CASE WHEN SUM(TOTAL_TOKENS) > 0
         THEN ROUND(SUM(INPUT_TOKENS) / SUM(TOTAL_TOKENS) * 100, 1)
         ELSE 0 END as INPUT_PCT
FROM AI_USAGE_MODEL_SUMMARY
WHERE USAGE_DATE >= DATEADD(day, -30, CURRENT_DATE())
GROUP BY MODEL_NAME
ORDER BY TOTAL_TOKENS DESC;

-- Task status
SHOW TASKS LIKE 'REFRESH_AI_USAGE_TASK';

-- =============================================================================
-- OPTIONAL: EMAIL ALERT ON BUDGET THRESHOLD (requires admin setup)
-- =============================================================================
-- To enable email alerts, an admin must first create a notification integration:
--
-- CREATE OR REPLACE NOTIFICATION INTEGRATION ai_budget_alert_email
--     TYPE = EMAIL
--     ENABLED = TRUE
--     ALLOWED_RECIPIENTS = ('admin@company.com');
--
-- Then create the alert:
--
-- CREATE OR REPLACE ALERT AI_BUDGET_ALERT
--     WAREHOUSE = <warehouse>
--     SCHEDULE = 'USING CRON 0 9 * * * America/Los_Angeles'
--     IF (EXISTS (
--         SELECT 1
--         FROM AI_USAGE_BUDGETS b
--         CROSS JOIN (
--             SELECT SUM(TOTAL_CREDITS) as total
--             FROM AI_USAGE_DAILY_SUMMARY
--             WHERE USAGE_DATE >= DATE_TRUNC('MONTH', CURRENT_DATE())
--         ) s
--         WHERE b.BUDGET_PERIOD = 'MONTHLY' AND b.IS_ACTIVE = TRUE
--           AND (s.total / b.BUDGET_CREDITS * 100) >= b.ALERT_THRESHOLD_PCT
--     ))
--     THEN
--         CALL SYSTEM$SEND_EMAIL(
--             'ai_budget_alert_email',
--             'admin@company.com',
--             'AI Budget Alert',
--             'Monthly AI budget threshold exceeded. Check the AI Monitoring Dashboard.'
--         );
--
-- ALTER ALERT AI_BUDGET_ALERT RESUME;

-- =============================================================================
-- GRANT PERMISSIONS (if using a separate app role)
-- =============================================================================
-- GRANT SELECT ON ALL TABLES IN SCHEMA <DB>.<SCHEMA> TO ROLE <YOUR_APP_ROLE>;
-- GRANT EXECUTE TASK ON ACCOUNT TO ROLE <YOUR_ADMIN_ROLE>;

-- =============================================================================
-- CLEANUP (if needed)
-- =============================================================================
-- ALTER TASK REFRESH_AI_USAGE_TASK SUSPEND;
-- DROP TASK IF EXISTS REFRESH_AI_USAGE_TASK;
-- DROP PROCEDURE IF EXISTS REFRESH_AI_USAGE_SUMMARIES(NUMBER);
-- DROP TABLE IF EXISTS AI_USAGE_DAILY_SUMMARY;
-- DROP TABLE IF EXISTS AI_USAGE_USER_SUMMARY;
-- DROP TABLE IF EXISTS AI_USAGE_MODEL_SUMMARY;
-- DROP TABLE IF EXISTS AI_USAGE_REFRESH_LOG;
