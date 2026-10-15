-- query_id: sf_wh_query_acceleration_eligible
-- title: Warehouses where Query Acceleration would help but is off
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_ELIGIBLE, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_eligible_hours (default 1) eligible hours: least a row needs before it can flag;
--   :warn_eligible_pct (default 10) eligible pct: at or above this the row reads WARN;
--   :crit_eligible_pct (default 30) eligible pct: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse with QAS-eligible queries. eligible_hours = execution time
--   Snowflake says the Query Acceleration Service could offload; eligible_pct = that as a share of the
--   warehouse's total execution time. p50/max_upper_limit_scale_factor = the scale factor that would
--   have given the full benefit.
-- healthy: status = OK when QAS is already enabled or eligible time is a small share of run time
-- investigate_if: WARN when QAS is off, eligible_hours >= min_eligible_hours and eligible_pct >=
--   warn_eligible_pct; CRITICAL when eligible_pct >= crit_eligible_pct
-- actions: 1) ALTER WAREHOUSE ... SET ENABLE_QUERY_ACCELERATION = TRUE,
--   QUERY_ACCELERATION_MAX_SCALE_FACTOR = suggested_scale_factor (config, spend); 2) watch the result
--   with sf_wh_query_acceleration_spend (free); 3) often cheaper than sizing the whole warehouse up for
--   a few large scans (spend)
-- next: none
-- caveats: eligible time is an upper bound on what QAS saves. QAS is billed per second of serverless
--   compute and needs Enterprise edition. The view has warehouse names only; ids come from SHOW
--   WAREHOUSES.
WITH __INCLUDE_warehouse_config__,
e AS (
  SELECT warehouse_name, COUNT(*) AS eligible_queries,
         COUNT(DISTINCT query_parameterized_hash) AS eligible_statement_shapes,
         SUM(eligible_query_acceleration_time) / 3600 AS eligible_hours,
         MEDIAN(upper_limit_scale_factor) AS p50_upper_limit_scale_factor,
         MAX(upper_limit_scale_factor) AS max_upper_limit_scale_factor
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_ELIGIBLE
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
x AS (
  SELECT warehouse_name, SUM(execution_time) / 3600000 AS exec_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
  GROUP BY 1
),
j AS (
  SELECT COALESCE(c.warehouse_id, e.warehouse_name) AS warehouse_id, e.warehouse_name, c.warehouse_size,
         LOWER(TO_VARCHAR(c.query_acceleration)) = 'true' AS qas_enabled,
         e.eligible_queries, e.eligible_statement_shapes, e.eligible_hours, x.exec_hours,
         100 * e.eligible_hours / NULLIF(x.exec_hours, 0) AS eligible_pct,
         e.p50_upper_limit_scale_factor, e.max_upper_limit_scale_factor
  FROM e
  LEFT JOIN warehouse_config c ON c.warehouse_name = e.warehouse_name
  LEFT JOIN x ON x.warehouse_name = e.warehouse_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, qas_enabled, eligible_queries, eligible_statement_shapes, eligible_hours,
       exec_hours AS execution_hours, eligible_pct,
       p50_upper_limit_scale_factor, max_upper_limit_scale_factor,
       -- the median factor covers most eligible queries without paying for the outliers
       CAST(LEAST(GREATEST(CEIL(p50_upper_limit_scale_factor), 1), 100) AS INTEGER) AS suggested_scale_factor,
       CASE WHEN warehouse_size IS NULL THEN 'warehouse_dropped' END AS not_assessed_reason,
       CASE
         WHEN warehouse_size IS NULL THEN 'NOT_ASSESSED'
         WHEN qas_enabled THEN 'OK'
         WHEN eligible_hours >= :min_eligible_hours AND eligible_pct >= :crit_eligible_pct THEN 'CRITICAL'
         WHEN eligible_hours >= :min_eligible_hours AND eligible_pct >= :warn_eligible_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY eligible_hours DESC NULLS LAST
