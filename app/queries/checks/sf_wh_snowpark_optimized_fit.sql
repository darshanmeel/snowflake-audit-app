-- query_id: sf_wh_snowpark_optimized_fit
-- title: Snowpark-optimized warehouses that run plain SQL
-- domain: compute   tier: standard
-- windowed: yes
-- money: est_saving_usd_list
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_snowpark_pct (default 10) percent of run time in stored procedure calls at or above which
--   the warehouse counts as running Snowpark work; :min_spill_pct (default 5) percent of run time in
--   statements that spilled at or above which it counts as needing the memory; :warn_credits (default
--   10) possible saving in credits at or above which a plain-SQL row reads WARN; :crit_credits (default
--   100) the same that reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one Snowpark-optimized warehouse (SHOW WAREHOUSES type SNOWPARK-OPTIMIZED). Its
--   statements in the window that ran while it was Snowpark-optimized (QUERY_HISTORY.WAREHOUSE_TYPE) are
--   split by run time: call_exec_pct in stored procedure calls (CALL, where Snowpark code runs) and
--   spill_exec_pct in statements that spilled to disk (memory pressure). verdict = snowpark_work when
--   either passes its threshold, plain_sql when neither does, no_premium when the resource constraint
--   bills the same rate as a standard warehouse. rate_multiplier is the hourly rate against a standard
--   Gen1 warehouse of the same size (Service Consumption Table, as in every warehouse check).
--   est_saving_credits = the credits Snowflake attributes to its queries in those statements' share of
--   run time, times (1 - 1 / rate_multiplier): what the same work costs less on a standard warehouse of
--   the same size. Idle time is left out (it is in the idle check), so the saving is never counted twice.
-- healthy: status = OK when the warehouse runs Snowpark work, pays no premium, or the saving is under
--   warn_credits
-- investigate_if: WARN when verdict = plain_sql and est_saving_credits >= warn_credits; CRITICAL when
--   >= crit_credits
-- actions: 1) check the warehouse's procedures and UDFs: if they need neither the memory nor the CPU
--   architecture, ALTER WAREHOUSE ... SET WAREHOUSE_TYPE = 'STANDARD' (suspend it first) (config); 2)
--   keep a small Snowpark-optimized warehouse for the procedures and move the SQL to a standard one
--   (config); 3) for MEMORY_16X or 64X, try a smaller resource constraint (config)
-- next: sf_wh_oversized, sf_wh_idle_minutes
-- not_assessed_reasons: no_queries: no statement ran on it as Snowpark-optimized in the window, so its work
--   cannot be judged (its idle time is in the idle check); unknown_size: no rate for its size and
--   resource constraint
-- caveats: heavy: reads QUERY_HISTORY for the window (period_days only), only for Snowpark-optimized
--   warehouses, aggregated in Snowflake. A SELECT that calls a Python or Java UDF looks like plain SQL
--   here, and a warehouse picked for an x86 library (MEMORY_*_X86) may need it for UDFs: check before
--   switching. The saving is an estimate at the same size; it can overlap the oversized check's saving
--   on the same warehouse.
WITH __INCLUDE_warehouse_config__,
so AS (
  SELECT * FROM warehouse_config WHERE warehouse_generation = 'SNOWPARK_OPTIMIZED'
),
qh AS (
  -- one row per warehouse: run time by kind of work, never per statement
  SELECT q.warehouse_name,
         COUNT_IF(UPPER(q.warehouse_type) = 'SNOWPARK-OPTIMIZED') AS queries,
         COUNT_IF(UPPER(q.warehouse_type) = 'SNOWPARK-OPTIMIZED' AND q.query_type = 'CALL') AS calls,
         SUM(q.execution_time) AS exec_ms_all,
         SUM(IFF(UPPER(q.warehouse_type) = 'SNOWPARK-OPTIMIZED', q.execution_time, 0)) AS exec_ms,
         SUM(IFF(UPPER(q.warehouse_type) = 'SNOWPARK-OPTIMIZED' AND q.query_type = 'CALL', q.execution_time, 0)) AS call_ms,
         SUM(IFF(UPPER(q.warehouse_type) = 'SNOWPARK-OPTIMIZED'
                 AND COALESCE(q.bytes_spilled_to_local_storage, 0) + COALESCE(q.bytes_spilled_to_remote_storage, 0) > 0,
                 q.execution_time, 0)) AS spill_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  JOIN so ON so.warehouse_name = q.warehouse_name
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
    AND q.execution_time > 0
  GROUP BY 1
),
m AS (
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits,
         SUM(credits_attributed_compute_queries) AS query_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
r AS (
  SELECT so.warehouse_id, so.warehouse_name, so.warehouse_size, so.resource_constraint, so.rate_multiplier,
         so.credits_per_hour, COALESCE(qh.queries, 0) AS queries, COALESCE(qh.calls, 0) AS calls,
         100 * qh.call_ms / NULLIF(qh.exec_ms, 0) AS call_exec_pct,
         100 * qh.spill_ms / NULLIF(qh.exec_ms, 0) AS spill_exec_pct,
         m.compute_credits, m.query_credits,
         -- the query credits in the share of run time it was Snowpark-optimized
         m.query_credits * COALESCE(qh.exec_ms / NULLIF(qh.exec_ms_all, 0), 0) AS so_query_credits
  FROM so
  LEFT JOIN qh ON qh.warehouse_name = so.warehouse_name
  LEFT JOIN m ON m.warehouse_name = so.warehouse_name
),
v AS (
  SELECT r.*,
         CASE WHEN queries = 0 THEN NULL
              WHEN COALESCE(rate_multiplier, 1) <= 1 THEN 'no_premium'
              WHEN COALESCE(call_exec_pct, 0) >= :min_snowpark_pct OR COALESCE(spill_exec_pct, 0) >= :min_spill_pct THEN 'snowpark_work'
              ELSE 'plain_sql' END AS verdict,
         COALESCE(so_query_credits, 0) * (1 - 1 / NULLIF(rate_multiplier, 0)) AS premium_credits
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, warehouse_size,
       resource_constraint, rate_multiplier, credits_per_hour, queries, calls,
       ROUND(call_exec_pct, 1) AS call_exec_pct, ROUND(spill_exec_pct, 1) AS spill_exec_pct,
       compute_credits, so_query_credits, verdict,
       IFF(verdict = 'plain_sql', premium_credits, 0) AS est_saving_credits,
       IFF(verdict = 'plain_sql', premium_credits, 0) * __CREDIT_PRICE__ AS est_saving_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN credits_per_hour IS NULL THEN 'unknown_size' WHEN queries = 0 THEN 'no_queries' END AS not_assessed_reason,
       CASE
         WHEN credits_per_hour IS NULL OR queries = 0 THEN 'NOT_ASSESSED'
         WHEN verdict = 'plain_sql' AND premium_credits >= :crit_credits THEN 'CRITICAL'
         WHEN verdict = 'plain_sql' AND premium_credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM v
ORDER BY est_saving_credits DESC NULLS LAST, warehouse_name
