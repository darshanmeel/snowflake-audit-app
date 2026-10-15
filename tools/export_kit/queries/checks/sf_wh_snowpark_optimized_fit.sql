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
WITH -- Current warehouse settings from the SHOW WAREHOUSES run just before (a check's `-- pre:` line),
-- with the numeric id taken from metering history by name. credits_per_hour is the Service
-- Consumption Table rate for the size, generation and resource constraint (rate_multiplier is its
-- ratio to a Gen1 standard warehouse of the same size; multi-cluster warehouses pay it per running
-- cluster; an estimate input, never billed spend). SHOW returns the counts and
-- auto_suspend as NUMBER, so they are cast, not TRY_TO_NUMBER'd (that takes text only).
-- An ADAPTIVE warehouse has no size, cluster counts or auto_suspend in SHOW, so those stay NULL.
warehouse_show AS (
  SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
-- Newer SHOW columns are read by key, since not every account returns them (is_interactive is AWS only).
warehouse_show_opt AS (
  SELECT r."name", r."type", r."size", r."state", r."min_cluster_count", r."max_cluster_count",
         r."auto_suspend", r."auto_resume", r."scaling_policy", r."resource_monitor", r."owner",
         r."enable_query_acceleration", r."updated_on", r."created_on",
         r.o:"resource_constraint"::VARCHAR AS "resource_constraint",
         r.o:"generation"::VARCHAR AS "generation",
         r.o:"is_interactive"::VARCHAR AS "is_interactive"
  FROM (SELECT w.*, OBJECT_CONSTRUCT(*) AS o FROM warehouse_show w) r
),
warehouse_config AS (
  SELECT COALESCE(TO_VARCHAR(ids.warehouse_id), s."name") AS warehouse_id,
         s."name" AS warehouse_name, s."type" AS warehouse_type, s."size" AS warehouse_size,
         s."state" AS warehouse_state,
         CAST(s."min_cluster_count" AS NUMBER) AS min_clusters,
         CAST(s."max_cluster_count" AS NUMBER) AS max_clusters,
         CAST(s."auto_suspend" AS NUMBER) / 60 AS auto_stop_minutes,
         s."auto_resume" AS auto_resume, s."scaling_policy" AS scaling_policy,
         s."resource_monitor" AS resource_monitor, s."owner" AS owner,
         s."enable_query_acceleration" AS query_acceleration, s."updated_on" AS updated_on,
         s."created_on" AS created_on,
         s."resource_constraint" AS resource_constraint,
         CASE WHEN UPPER(s."type") = 'ADAPTIVE' THEN 'ADAPTIVE'
              WHEN UPPER(s."type") = 'SNOWPARK-OPTIMIZED' THEN 'SNOWPARK_OPTIMIZED'
              WHEN UPPER(COALESCE(s."resource_constraint", '')) = 'STANDARD_GEN_2'
                   OR s."generation" = '2' THEN 'GEN2'
              ELSE 'GEN1' END AS warehouse_generation,
         CASE UPPER(REPLACE(s."size", '-', ''))
           WHEN 'XSMALL' THEN 1 WHEN 'SMALL' THEN 2 WHEN 'MEDIUM' THEN 4 WHEN 'LARGE' THEN 8
           WHEN 'XLARGE' THEN 16 WHEN '2XLARGE' THEN 32 WHEN 'XXLARGE' THEN 32
           WHEN '3XLARGE' THEN 64 WHEN 'XXXLARGE' THEN 64 WHEN '4XLARGE' THEN 128
           WHEN '5XLARGE' THEN 256 WHEN '6XLARGE' THEN 512
         END * s.rate_multiplier AS credits_per_hour,
         s.rate_multiplier
  FROM (
    -- Multipliers from Tables 1(b) to 1(d) of the Service Consumption Table (Gen2 is 1.25 on Azure,
    -- 1.35 elsewhere; Snowpark-optimized by resource constraint; interactive 0.6).
    SELECT r.*, CASE
      -- adaptive warehouses have no fixed hourly rate: unknown, never a size-based guess
      WHEN UPPER(r."type") = 'ADAPTIVE' THEN CAST(NULL AS DOUBLE)
      WHEN UPPER(r."type") = 'SNOWPARK-OPTIMIZED' THEN
        -- MEMORY_16X is the documented default for Snowpark-optimized (CREATE WAREHOUSE)
        CASE UPPER(COALESCE(r."resource_constraint", 'MEMORY_16X'))
          WHEN 'MEMORY_1X_X86' THEN 1.1 WHEN 'MEMORY_16X' THEN 1.5 WHEN 'MEMORY_16X_X86' THEN 1.5625
          WHEN 'MEMORY_64X' THEN 1.875 WHEN 'MEMORY_64X_X86' THEN 2.0 ELSE 1.0 END
      WHEN UPPER(r."type") = 'INTERACTIVE' OR LOWER(r."is_interactive") IN ('true', 'y') THEN 0.6
      WHEN UPPER(COALESCE(r."resource_constraint", '')) = 'STANDARD_GEN_2' OR r."generation" = '2'
        THEN IFF(__CLOUD__ = 'AZURE', 1.25, 1.35)
      ELSE 1.0 END AS rate_multiplier
    FROM warehouse_show_opt r
  ) s
  LEFT JOIN (
    SELECT warehouse_name, MAX(warehouse_id) AS warehouse_id
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD(day, -400, __AS_OF_DATE__)
    GROUP BY warehouse_name
  ) ids ON ids.warehouse_name = s."name"
),
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
