# Agent Deployment Guide: AI Monitoring Dashboard

This guide enables an AI agent (Cortex Code, Claude, etc.) to deploy the Cortex Tracker AI Monitoring Dashboard end-to-end on any Snowflake account.

---

## Prerequisites

- **Role**: ACCOUNTADMIN (or a role with `IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE`, `CREATE TABLE`, `CREATE PROCEDURE`, `CREATE TASK`, `EXECUTE TASK`, `CREATE STREAMLIT`)
- **Snowflake CLI**: `snow` v3.14.0+ (check with `snow --version`)
- **Warehouse**: Any XS or larger warehouse

---

## Step 0: Gather Configuration from User (REQUIRED)

**Before doing anything else, ask the user for ALL of the following configuration values.** Do not assume defaults without confirmation.

### Questions to ask:

1. **Database**: Which database should the dashboard tables and app be deployed to?
   - Default suggestion: `SAMPLES_DB`

2. **Schema**: Which schema within that database?
   - Default suggestion: `PUBLIC`

3. **Warehouse**: Which warehouse should the app and task use?
   - Default suggestion: `COMPUTE_WH`

4. **Default Timezone**: What timezone should the dashboard default to for displaying dates?
   - Options: `America/Los_Angeles`, `America/New_York`, `America/Chicago`, `America/Denver`, `UTC`, `Europe/London`, `Europe/Paris`, `Asia/Tokyo`, `Australia/Sydney`
   - Default suggestion: `America/Los_Angeles`

5. **Task Schedule Timezone**: What timezone should the scheduled refresh task use?
   - Default suggestion: Same as dashboard timezone

6. **Task Schedule**: How often should data refresh?
   - Default suggestion: Every 12 hours (`USING CRON 0 0,12 * * * <TIMEZONE>`)

7. **Streamlit App Name**: What should the deployed Streamlit app be called?
   - Default suggestion: `CORTEX_TRACKER`

8. **Initial Backfill Days**: How many days of historical data to load?
   - Default suggestion: `365`

### Store these as variables for the rest of the deployment:

```
DB_NAME        = <user's answer to #1>
SCHEMA_NAME    = <user's answer to #2>
WAREHOUSE_NAME = <user's answer to #3>
DEFAULT_TZ     = <user's answer to #4>
TASK_TZ        = <user's answer to #5>
TASK_SCHEDULE  = <user's answer to #6>
APP_NAME       = <user's answer to #7>
BACKFILL_DAYS  = <user's answer to #8>
```

---

## Step 1: Update configuration files

### 1a. Update `config.py`

Set `SUMMARY_SCHEMA` on line 1:
```python
SUMMARY_SCHEMA = "<DB_NAME>.<SCHEMA_NAME>"
```

Set `DEFAULT_TIMEZONE` on line 15:
```python
DEFAULT_TIMEZONE = "<DEFAULT_TZ>"
```

### 1b. Update `setup.sql` / `setup.txt` (lines 34-37)

```sql
SET DB_NAME = '<DB_NAME>';
SET SCHEMA_NAME = '<SCHEMA_NAME>';
SET WAREHOUSE_NAME = '<WAREHOUSE_NAME>';
SET TASK_TIMEZONE = '<TASK_TZ>';
```

### 1c. Update `snowflake.yml`

```yaml
definition_version: 2
entities:
  cortex_tracker:
    type: streamlit
    identifier:
      name: <APP_NAME>
      database: <DB_NAME>
      schema: <SCHEMA_NAME>
    query_warehouse: <WAREHOUSE_NAME>
    runtime_name: SYSTEM$ST_CONTAINER_RUNTIME_PY3_11
    compute_pool: <COMPUTE_POOL>  # Determined in Step 5
    main_file: streamlit_app.py
    artifacts:
      - streamlit_app.py
      - config.py
      - utils.py
      - queries_summary.py
      - queries_raw.py
      - queries_observability.py
```

---

## Step 2: Create backend tables

Execute each CREATE TABLE statement from `setup.sql` against the target schema. There are 6 tables:

1. `AI_USAGE_DAILY_SUMMARY` - aggregated daily metrics by feature/model
2. `AI_USAGE_USER_SUMMARY` - per-user daily metrics
3. `AI_USAGE_MODEL_SUMMARY` - per-model daily metrics
4. `AI_USAGE_REFRESH_LOG` - tracks refresh procedure runs
5. `AI_USAGE_BUDGETS` - configurable credit budgets
6. `AI_USAGE_USER_THRESHOLDS` - per-user anomaly thresholds

First set session context:
```sql
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
```

Then run all 6 CREATE TABLE statements, followed by default inserts:
```sql
INSERT INTO AI_USAGE_BUDGETS (BUDGET_NAME, BUDGET_PERIOD, FEATURE_NAME, BUDGET_CREDITS, ALERT_THRESHOLD_PCT, CREATED_BY)
VALUES ('Default Monthly Budget', 'MONTHLY', NULL, 1000, 80, CURRENT_USER());

INSERT INTO AI_USAGE_USER_THRESHOLDS (USER_NAME, FEATURE_NAME, MAX_DAILY_CREDITS, MULTIPLIER_ALERT, CREATED_BY)
VALUES (NULL, NULL, 100, 3, CURRENT_USER());
```

---

## Step 3: Create the stored procedure

Execute the full `CREATE OR REPLACE PROCEDURE REFRESH_AI_USAGE_SUMMARIES(...)` from `setup.sql`.

**Critical**: The procedure uses unqualified table names (e.g., `AI_USAGE_DAILY_SUMMARY` not `DB.SCHEMA.AI_USAGE_DAILY_SUMMARY`). You MUST either:
- Set `USE DATABASE <DB_NAME>` and `USE SCHEMA <SCHEMA_NAME>` before creating it (recommended), OR
- Search-replace all table names in the procedure body to be fully qualified

---

## Step 4: Run initial backfill

```sql
CALL <DB_NAME>.<SCHEMA_NAME>.REFRESH_AI_USAGE_SUMMARIES(<BACKFILL_DAYS>);
```

This takes 30-120 seconds depending on account data volume. Check results:

```sql
SELECT REFRESH_MODE, STATUS, SOURCE_ERRORS, ROWS_DAILY, ROWS_USER, ROWS_MODEL,
       DATEDIFF(second, REFRESH_START, REFRESH_END) as DURATION_SEC
FROM <DB_NAME>.<SCHEMA_NAME>.AI_USAGE_REFRESH_LOG ORDER BY REFRESH_START DESC LIMIT 1;
```

**Expected**: STATUS = `SUCCESS` or `PARTIAL` (PARTIAL is OK - it means some preview views like Agents or Intelligence don't exist in this account yet).

---

## Step 5: Create and resume the scheduled task

```sql
CREATE OR REPLACE TASK <DB_NAME>.<SCHEMA_NAME>.REFRESH_AI_USAGE_TASK
    WAREHOUSE = <WAREHOUSE_NAME>
    SCHEDULE = '<TASK_SCHEDULE>'
    COMMENT = 'Twice-daily incremental refresh of AI usage summary tables'
AS
    CALL <DB_NAME>.<SCHEMA_NAME>.REFRESH_AI_USAGE_SUMMARIES(0);

ALTER TASK <DB_NAME>.<SCHEMA_NAME>.REFRESH_AI_USAGE_TASK RESUME;
```

The default schedule is: `USING CRON 0 0,12 * * * <TASK_TZ>`

---

## Step 6: Deploy Streamlit app

### 6a. Determine compute_pool

```sql
SHOW PARAMETERS LIKE 'DEFAULT_STREAMLIT_COMPUTE_POOL' IN ACCOUNT;
```
Use the `value` column (e.g., `SYSTEM_COMPUTE_POOL_CPU`). Set this as `<COMPUTE_POOL>` in `snowflake.yml`.

### 6b. Deploy

```bash
snow streamlit deploy cortex_tracker -c <CONNECTION_NAME> --replace
```

**If this is a fresh deploy on a clean stage**: Just deploy normally.

**If redeploying over an existing app**: The stage may retain stale files (`.streamlit/config.toml`, `pyproject.toml`) from a previous deployment. If a stale `pyproject.toml` exists on stage, the container runtime will try to resolve packages from PyPI, which requires an External Access Integration (EAI). Either:
- Add an EAI: `ALTER STREAMLIT <DB_NAME>.<SCHEMA_NAME>.<APP_NAME> SET EXTERNAL_ACCESS_INTEGRATIONS = (ALLOW_ALL_INTEGRATION)` (or whichever EAI exists), OR
- Drop and recreate: `DROP STREAMLIT <DB_NAME>.<SCHEMA_NAME>.<APP_NAME>` then deploy fresh (note: the internal stage persists even after DROP - this is a known Snowflake behavior)

### 6c. Verify deployment

```sql
SHOW STREAMLITS LIKE '<APP_NAME>' IN ACCOUNT;
```
Expect 1 row. If 0 rows, the deploy silently failed.

---

## Step 7: Verify end-to-end

```sql
-- Row counts
SELECT 'DAILY' as TBL, COUNT(*) as ROW_COUNT FROM <DB_NAME>.<SCHEMA_NAME>.AI_USAGE_DAILY_SUMMARY
UNION ALL SELECT 'USER', COUNT(*) FROM <DB_NAME>.<SCHEMA_NAME>.AI_USAGE_USER_SUMMARY
UNION ALL SELECT 'MODEL', COUNT(*) FROM <DB_NAME>.<SCHEMA_NAME>.AI_USAGE_MODEL_SUMMARY;

-- Task is running
SHOW TASKS LIKE 'REFRESH_AI_USAGE_TASK' IN SCHEMA <DB_NAME>.<SCHEMA_NAME>;
-- state should be 'started'

-- Streamlit exists
SHOW STREAMLITS LIKE '<APP_NAME>' IN ACCOUNT;
```

---

## Key Gotchas and Learnings

### Snow CLI Connection Issues

- The `snow connection list` command may error with `'String' object has no attribute 'items'` due to config file formatting issues. This is non-blocking - you can still deploy.
- OAuth-based connections (`authenticator = oauth_authorization_code`) will timeout in headless/CLI environments. Use a connection with a PAT token instead.
- If multiple connections exist, use the `-c <CONNECTION_NAME>` flag explicitly.

### Streamlit Stage Persistence

- The internal Streamlit stage (`snow://streamlit/<DB>.<SCHEMA>.<NAME>/versions/live/`) persists even after `DROP STREAMLIT`. Files from previous deployments remain.
- The `--prune` flag on `snow streamlit deploy` may fail with "Cannot perform STAGE RM. This session does not have a current schema." This is a known CLI bug. Workaround: deploy without `--prune` (stale files are harmless unless they include `pyproject.toml`).
- A stale `pyproject.toml` on stage triggers PyPI package resolution, which requires an EAI. If you see the app fail with "Failed to retrieve packages from the package server", add an EAI or drop+recreate.

### No `pyproject.toml` Needed

This app only uses `streamlit`, `pandas`, and `altair` - all pre-installed in the container runtime. Do NOT include a `pyproject.toml` in artifacts. This avoids the EAI requirement entirely.

### Container Runtime is Required

Always use `runtime_name: SYSTEM$ST_CONTAINER_RUNTIME_PY3_11`. Never fall back to warehouse runtime (definition_version 1.1). The app uses multi-file imports (`from config import ...`, `from utils import ...`) which require the container runtime.

### PARTIAL Refresh Status is Normal

The stored procedure wraps each of 12 ACCOUNT_USAGE views in TRY/CATCH. Views that don't exist in the account (e.g., `CORTEX_AGENT_USAGE_HISTORY` in accounts that haven't used Agents) will fail gracefully and be logged in `SOURCE_ERRORS`. STATUS = `PARTIAL` means some sources had no data or don't exist - the app still works for all other features.

### App Uses `get_active_session()`

The Streamlit app uses `from snowflake.snowpark.context import get_active_session` (not `st.connection()`). This is the correct pattern for SiS apps running in the container runtime. No secrets or connection config is needed - the app inherits the session of the user viewing it.

### Data Latency

ACCOUNT_USAGE views have 2-3 hour latency. The task refreshes every 12 hours. End-to-end latency is 2-15 hours. For fresher data, run `CALL REFRESH_AI_USAGE_SUMMARIES(0)` manually.

---

## File Inventory

| File | Purpose | Deployed to SiS? |
|------|---------|-------------------|
| `streamlit_app.py` | Main app (13 tabs, 400+ lines) | Yes |
| `config.py` | Schema config, timezone, credit type mappings | Yes |
| `utils.py` | Helper functions (formatting, date math) | Yes |
| `queries_summary.py` | Queries against summary tables | Yes |
| `queries_raw.py` | Queries against raw ACCOUNT_USAGE views | Yes |
| `queries_observability.py` | Agent observability queries | Yes |
| `setup.sql` | Backend setup (tables, proc, task) | No (run manually) |
| `setup.txt` | Same as setup.sql (text copy) | No |
| `snowflake.yml` | CLI deploy manifest | No (local only) |
| `environment.yml` | Conda env spec (reference only) | No |
| `README.md` | Human documentation | No |
| `agent.md` | This file | No |

---

## Quick Deploy Checklist

1. [ ] Asked user for: database, schema, warehouse, timezone, task schedule, app name, backfill days
2. [ ] `config.py` updated with correct `SUMMARY_SCHEMA` and `DEFAULT_TIMEZONE`
3. [ ] `setup.sql`/`setup.txt` updated with correct DB/schema/warehouse/timezone
4. [ ] `snowflake.yml` created with correct values + compute_pool from account
5. [ ] 6 tables created in target schema
6. [ ] Default budget + threshold rows inserted
7. [ ] Stored procedure created (with correct session context)
8. [ ] `CALL REFRESH_AI_USAGE_SUMMARIES(<BACKFILL_DAYS>)` completed (STATUS = SUCCESS or PARTIAL)
9. [ ] Task created and resumed (state = started)
10. [ ] `snow streamlit deploy` succeeded
11. [ ] `SHOW STREAMLITS LIKE '<APP_NAME>'` returns 1 row
12. [ ] App loads in browser (not "Example Streamlit App")
