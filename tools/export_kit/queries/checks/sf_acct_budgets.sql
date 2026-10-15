-- query_id: sf_acct_budgets
-- title: Budgets covering serverless and non-warehouse spend
-- domain: cost   tier: standard
-- entity: budgets = database_name, schema_name, budget_name
-- windowed: yes
-- pre: SHOW SNOWFLAKE.CORE.BUDGET INSTANCES IN ACCOUNT
-- reads: SHOW SNOWFLAKE.CORE.BUDGET INSTANCES IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; the SNOWFLAKE.BUDGET_VIEWER application role
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 500) usd: at or above this the row reads WARN; :crit_usd (default 5000)
--   usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one ACCOUNT row plus one row per custom budget. Resource monitors only cap warehouses;
--   budgets are Snowflake's only guard that also notifies on serverless spend (tasks, Snowpipe,
--   clustering, Cortex, replication, ...). serverless_credits is the account's non-warehouse credits in
--   the window (METERING_HISTORY, service types other than WAREHOUSE_METERING*). custom_budgets counts
--   budget instances besides the account root budget.
-- healthy: status = OK when at least one custom budget exists, or serverless spend is under warn_usd.
-- investigate_if: WARN when there is no custom budget and serverless spend >= warn_usd; CRITICAL when
--   there is none and it is >= crit_usd.
-- actions: 1) activate the account budget and set a monthly limit and email notification (config); 2)
--   create custom budgets per team or product holding their databases, warehouses and serverless
--   objects (config); 3) review each budget's limit against the month-end forecast (free).
-- next: none
-- caveats: SHOW ... BUDGET INSTANCES needs a role granted the budget viewer application roles or
--   ACCOUNTADMIN; if it fails the check fails and is reported by the exporter. Whether the account root
--   budget is activated and each budget's spending limit are only readable with CALL, which this
--   read-only audit does not run, so budget_limit is not shown.
WITH b AS (
  SELECT "name" AS budget_name, "database_name" AS database_name, "schema_name" AS schema_name,
         "owner" AS budget_owner, CAST("created_on" AS TIMESTAMP_LTZ) AS created_on, "comment" AS comment,
         UPPER("name") = 'ACCOUNT_ROOT_BUDGET' AS is_root
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
m AS (
  SELECT SUM(credits_used) AS total_credits,
         SUM(IFF(service_type NOT LIKE 'WAREHOUSE_METERING%', credits_used, 0)) AS serverless_credits,
         LISTAGG(DISTINCT IFF(service_type NOT LIKE 'WAREHOUSE_METERING%', service_type, NULL), ', ')
           WITHIN GROUP (ORDER BY IFF(service_type NOT LIKE 'WAREHOUSE_METERING%', service_type, NULL))
           AS serverless_services
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
c AS (
  SELECT COUNT_IF(NOT is_root) AS custom_budgets, COUNT_IF(is_root) > 0 AS root_listed FROM b
),
acct AS (
  SELECT 'ACCOUNT' AS row_type, CAST(NULL AS VARCHAR) AS budget_name, CAST(NULL AS VARCHAR) AS database_name,
         CAST(NULL AS VARCHAR) AS schema_name, CAST(NULL AS VARCHAR) AS budget_owner,
         CAST(NULL AS TIMESTAMP_LTZ) AS created_on, CAST(NULL AS VARCHAR) AS comment,
         c.custom_budgets, c.root_listed, m.total_credits, m.serverless_credits, m.serverless_services,
         m.serverless_credits * __CREDIT_PRICE__ AS usd
  FROM c CROSS JOIN m
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       row_type, budget_name, database_name, schema_name, budget_owner, created_on, comment,
       custom_budgets, root_listed, total_credits, serverless_credits, serverless_services,
       usd AS est_serverless_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(custom_budgets = 0,
           'no custom budget; ' || ROUND(serverless_credits, 1) || ' serverless credits in the window are only capped by the account budget, if activated',
           custom_budgets || ' custom budget(s)') AS reasons,
       CASE WHEN custom_budgets = 0 AND __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN custom_budgets > 0 THEN 'OK'
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM acct
UNION ALL
SELECT :period_days, __ACCOUNT_ID__,
       IFF(b.is_root, 'ROOT_BUDGET', 'BUDGET'), b.budget_name, b.database_name, b.schema_name, b.budget_owner,
       b.created_on, b.comment, NULL, NULL, NULL, NULL, NULL, NULL,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced'),
       IFF(b.is_root, 'account root budget (activation not readable)', 'custom budget'),
       NULL, 'OK'
FROM b
ORDER BY row_type, budget_name
