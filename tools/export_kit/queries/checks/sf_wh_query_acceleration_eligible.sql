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
