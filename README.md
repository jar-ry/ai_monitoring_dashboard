# AI Monitoring Dashboard

Enterprise monitoring dashboard for **all** Snowflake Cortex AI features, built as a Streamlit in Snowflake (SiS) application.

<!-- Add screenshots here after deployment:
![Dashboard Overview](screenshots/overview.png)
![Features Tab](screenshots/features.png)
![Model Usage](screenshots/models.png)
-->

---

## Overview

This dashboard provides unified visibility into AI/ML credit consumption, token usage, and user activity across every Snowflake Cortex AI service. It replaces manual queries against `ACCOUNT_USAGE` views with pre-aggregated summary tables for instant load times.

### AI Features Monitored

| Feature | Source View | Status |
|---------|-----------|--------|
| Cortex AI Functions (COMPLETE, TRANSLATE, etc.) | `CORTEX_AISQL_USAGE_HISTORY` | GA |
| Cortex AI Functions (historical) | `CORTEX_FUNCTIONS_USAGE_HISTORY` | Deprecated (pre-Nov 2025) |
| Cortex Analyst (Text-to-SQL) | `CORTEX_ANALYST_USAGE_HISTORY` | GA |
| Cortex Search (Query + Serving) | `CORTEX_SEARCH_DAILY_USAGE_HISTORY` | GA |
| Cortex Fine-tuning | `CORTEX_FINE_TUNING_USAGE_HISTORY` | GA |
| Document AI / AI Extract | `CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY` | GA |
| Cortex REST API | `CORTEX_REST_API_USAGE_HISTORY` | GA |
| Cortex Agents | `CORTEX_AGENT_USAGE_HISTORY` | Preview |
| Snowflake Intelligence | `SNOWFLAKE_INTELLIGENCE_USAGE_HISTORY` | Preview |

### Credit Type Classification

As of April 6, 2026, Snowflake bills AI features under distinct credit types. The dashboard color-codes all visualizations and adds a `CREDIT_TYPE` column to data tables:

| Credit Type | Color | Features |
|---|---|---|
| **AI Credits** | Purple (`#7C3AED`) | Cortex Agents, Cortex Code (CLI + Snowsight), Snowflake Intelligence |
| **Regular Credits** | Blue (`#29B5E8`) | AI Functions, Analyst, Search, Fine-tuning, Document AI, Provisioned Throughput |
| **Dollars** | Amber (`#F59E0B`) | Cortex REST API (billed in USD, not credits) |

---

## Architecture

```
                        SNOWFLAKE.ACCOUNT_USAGE
                    (9 AI usage views, 2-3 hr latency)
                                |
                                v
                 +------------------------------+
                 | REFRESH_AI_USAGE_SUMMARIES() |
                 |     Stored Procedure          |
                 |  - Per-source TRY/CATCH       |
                 |  - Incremental refresh        |
                 |  - v_has_aisql fallback logic |
                 +------------------------------+
                                |
                  +-------------+-------------+
                  |             |             |
                  v             v             v
         AI_USAGE_DAILY  AI_USAGE_USER  AI_USAGE_MODEL
           _SUMMARY        _SUMMARY       _SUMMARY
                  |             |             |
                  +-------------+-------------+
                                |
                                v
                    +--------------------+
                    | Streamlit App      |
                    | (instant queries)  |
                    +--------------------+
                                ^
                                |
                   REFRESH_AI_USAGE_TASK
                    (every 12 hours, incremental)
```

### How It Works

1. **Setup (`setup.txt`)**: Creates summary tables, the stored procedure, a scheduled task, and optional budget/threshold tables.

2. **Stored Procedure (`REFRESH_AI_USAGE_SUMMARIES`)**: Queries all 9 `ACCOUNT_USAGE` AI views and aggregates them into 3 summary tables (daily, user, model). Each source is wrapped in its own `TRY/CATCH` block so one failing view doesn't block others.

3. **Incremental Refresh**: When called with `DAYS_TO_REFRESH = 0` (the default for the scheduled task), the procedure reads the last successful refresh timestamp and only processes new data since then (with a 3-day overlap for late-arriving records).

4. **Streamlit App (`streamlit_app.py`)**: Reads from summary tables with 60-second cache TTL. All queries use `COALESCE` to handle NULLs and have fallback queries for backward compatibility.

### Key Design Decisions

- **`v_has_aisql` flag**: `CORTEX_AISQL_USAGE_HISTORY` (GA Dec 2025) may not exist in all accounts. If it doesn't, the deprecated `CORTEX_FUNCTIONS_USAGE_HISTORY` view automatically loads all data instead of only pre-Nov 2025 data.

- **LATERAL FLATTEN for Agents/Intelligence**: These preview views have no time column. The timestamp is extracted from `TOKENS_GRANULAR` JSON using `LATERAL FLATTEN(input => TOKENS_GRANULAR[0])` and `f.value:start_time::TIMESTAMP_NTZ`.

- **TRY_TO_NUMBER for VARIANT columns**: `TOKENS_GRANULAR:input` returns VARIANT type. Snowflake's `TRY_CAST` doesn't work with VARIANT-to-NUMBER, so we use `TRY_TO_NUMBER(col::VARCHAR)` instead.

---

## Installation

### Prerequisites

```sql
-- Required: access to ACCOUNT_USAGE views
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <YOUR_ROLE>;
```

### Step 1: Configure and Run Setup

Edit the top of `setup.txt` to set your environment:

```sql
SET DB_NAME = 'SAMPLES_DB';         -- Your database
SET SCHEMA_NAME = 'PUBLIC';          -- Your schema
SET WAREHOUSE_NAME = 'COMPUTE_WH';  -- Your warehouse
```

Run `setup.txt` in a Snowflake worksheet. This creates:
- 6 tables (3 summary + refresh log + budgets + thresholds)
- 1 stored procedure (`REFRESH_AI_USAGE_SUMMARIES`)
- 1 scheduled task (`REFRESH_AI_USAGE_TASK`)

### Step 2: Initial Data Load

```sql
-- Start with 30 days to validate quickly
CALL REFRESH_AI_USAGE_SUMMARIES(30);

-- Check the refresh log for errors
SELECT * FROM AI_USAGE_REFRESH_LOG ORDER BY REFRESH_START DESC LIMIT 5;

-- If clean, backfill more history
CALL REFRESH_AI_USAGE_SUMMARIES(90);
CALL REFRESH_AI_USAGE_SUMMARIES(365);
```

> **Loading Time**: A 365-day full refresh on a large account can take several minutes. Use a MEDIUM or LARGE warehouse for faster initial loads. Subsequent incremental refreshes (via the scheduled task) take seconds.

### Step 3: Deploy Streamlit App

1. Open Snowsight > Projects > Streamlit
2. Create a new Streamlit app in the **same database and schema** (e.g., `SAMPLES_DB.PUBLIC`)
3. Paste the contents of `streamlit_app.py`
4. Verify `SUMMARY_SCHEMA` in `config.py` matches your `DB.SCHEMA`
5. Run

### Step 4: Resume the Scheduled Task

```sql
ALTER TASK REFRESH_AI_USAGE_TASK RESUME;
```

This runs `REFRESH_AI_USAGE_SUMMARIES(0)` every 12 hours (incremental mode).

---

## Dashboard Tabs

### Tab 1: Overview
Top-level KPIs: Total Credits, Total Tokens, API Calls, Active Users, New Users, Cost/1M Tokens. Includes period-over-period comparison with delta indicators.

### Tab 2: Features
Credit breakdown by AI feature (Cortex Functions, Analyst, Search, Agents, etc.) with percentage of total, token counts, and call volumes.

### Tab 3: Model Usage
LLM model breakdown showing credits, tokens, and calls per model (e.g., `claude-4-sonnet`, `llama3.1-70b`). Helps identify cost-performance tradeoffs.

### Tab 4: Trends
Daily/weekly credit trends with charts, week-over-week comparisons, and category breakdowns over time.

### Tab 5: Users
Top users by credit consumption, new user activity, and per-user anomaly detection (z-score based).

### Tab 6: Efficiency
Cost efficiency metrics by model: tokens per credit, credits per 1K calls, input/output token split.

### Tab 7: Budgets
Configure credit budgets (daily/monthly/quarterly) with alert thresholds. Visual progress bars show budget utilization.

### Tab 8: Operations
- **Refresh Log**: Status of each stored procedure run (SUCCESS/PARTIAL/FAILED)
- **Task History**: Scheduled task execution history
- **Data Completeness**: Which AI source categories have data
- **Reconciliation**: Compare summary table totals vs `METERING_DAILY_HISTORY` for validation

### Tab 9: Raw Data
Export any data source (feature summary, users, models, daily credits, Cortex Analyst/Search/Document AI details) to CSV.

---

## Troubleshooting

### "No data" or empty tabs
1. Check the refresh log: `SELECT * FROM AI_USAGE_REFRESH_LOG ORDER BY REFRESH_START DESC;`
2. Look at `SOURCE_ERRORS` column for specific view failures
3. Run a manual refresh: `CALL REFRESH_AI_USAGE_SUMMARIES(30);`

### Partial refresh (some sources failed)
This is expected. Views in **preview** (Agents, Intelligence) or **GA but not yet available** in your account (AISQL) will fail gracefully. The procedure continues loading all other sources.

### Slow dashboard loading
The dashboard reads from pre-aggregated tables - it should load in under 2 seconds. If slow:
- Check that the Streamlit app warehouse is running
- Verify `SUMMARY_SCHEMA` in `config.py` points to the correct database/schema

### AISQL view doesn't exist
Normal for some accounts. The `v_has_aisql` flag ensures `CORTEX_FUNCTIONS_USAGE_HISTORY` (deprecated) loads all data automatically as a fallback.

---

## Files

| File | Description |
|------|-------------|
| `setup.txt` | SQL setup script: tables, stored procedure, task, budgets |
| `streamlit_app.py` | Streamlit in Snowflake application code |
| `environment.yml` | Streamlit environment configuration |
| `README.md` | This documentation |

---

## Configuration

### Stored Procedure Parameters

| Parameter | Description |
|-----------|-------------|
| `DAYS_TO_REFRESH = 0` | **Incremental** mode: loads only since last refresh (+ 3-day overlap) |
| `DAYS_TO_REFRESH = 30` | Loads last 30 days (full replace for that window) |
| `DAYS_TO_REFRESH = 365` | Loads last 365 days (full backfill) |

### App Configuration

Update `SUMMARY_SCHEMA` in `config.py` if your database/schema differs:

```python
SUMMARY_SCHEMA = "SAMPLES_DB.PUBLIC"
```

---

## Data Latency

| Component | Latency |
|-----------|---------|
| ACCOUNT_USAGE views | 2-3 hours |
| Scheduled task refresh | Every 12 hours |
| Streamlit cache TTL | 60 seconds |
| **End-to-end** | **2-15 hours** (depending on task schedule) |

For near-real-time data, run the stored procedure manually:

```sql
CALL REFRESH_AI_USAGE_SUMMARIES(0);  -- incremental, takes seconds
```
