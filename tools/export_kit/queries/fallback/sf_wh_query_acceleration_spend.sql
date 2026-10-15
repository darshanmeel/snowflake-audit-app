-- query_id: sf_wh_query_acceleration_spend
-- shims: WAREHOUSE_METERING_HISTORY, QUERY_ACCELERATION_HISTORY, QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, QUERY_ACCELERATION_HISTORY, QUERY_HISTORY
-- fallback_note: warehouse credits for 6 months at most; adaptive warehouses left out; the warehouse name stands in for its id; no per-query attribution; query acceleration credits for 6 months at most; the warehouse name stands in for its id; queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
-- needs: MONITOR USAGE
-- pre: SHOW WAREHOUSES
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
    FROM __SHIM_WAREHOUSE_METERING_HISTORY__
    WHERE start_time >= DATEADD(day, -400, __AS_OF_DATE__)
    GROUP BY warehouse_name
  ) ids ON ids.warehouse_name = s."name"
),
sf AS (
  SELECT s."name" AS warehouse_name,
         TRY_TO_NUMBER(TO_VARCHAR(s."query_acceleration_max_scale_factor")) AS max_scale_factor
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
),
a AS (
  SELECT warehouse_name, MAX(TO_VARCHAR(warehouse_id)) AS warehouse_id, SUM(credits_used) AS qas_credits
  FROM __SHIM_QUERY_ACCELERATION_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
  HAVING SUM(credits_used) > 0
),
m AS (
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits
  FROM __SHIM_WAREHOUSE_METERING_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
q AS (
  SELECT warehouse_name, COUNT(*) AS accelerated_queries,
         COUNT(DISTINCT query_parameterized_hash) AS accelerated_statement_shapes
  FROM __SHIM_QUERY_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_acceleration_bytes_scanned > 0
  GROUP BY 1
),
j AS (
  SELECT a.warehouse_id, a.warehouse_name, c.warehouse_size,
         LOWER(TO_VARCHAR(c.query_acceleration)) = 'true' AS qas_enabled, sf.max_scale_factor,
         a.qas_credits, m.compute_credits,
         q.accelerated_queries, q.accelerated_statement_shapes,
         100 * a.qas_credits / NULLIF(m.compute_credits, 0) AS qas_share_pct
  FROM a
  LEFT JOIN warehouse_config c ON c.warehouse_name = a.warehouse_name
  LEFT JOIN sf ON sf.warehouse_name = a.warehouse_name
  LEFT JOIN m ON m.warehouse_name = a.warehouse_name
  LEFT JOIN q ON q.warehouse_name = a.warehouse_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, qas_enabled, CAST(max_scale_factor AS INTEGER) AS max_scale_factor,
       accelerated_queries, accelerated_statement_shapes,
       qas_credits, qas_credits * __CREDIT_PRICE__ AS est_qas_usd_list,
       compute_credits, compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list, qas_share_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN qas_share_pct >= :crit_share_pct OR qas_credits >= :crit_credits THEN 'CRITICAL'
         WHEN qas_share_pct >= :warn_share_pct OR qas_credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY qas_credits DESC
