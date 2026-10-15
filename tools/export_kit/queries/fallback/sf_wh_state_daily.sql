-- query_id: sf_wh_state_daily
-- shims: WAREHOUSE_METERING_HISTORY, WAREHOUSE_LOAD_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, WAREHOUSE_LOAD_HISTORY (table function, per warehouse)
-- fallback_note: warehouse credits for 6 months at most; adaptive warehouses left out; the warehouse name stands in for its id; no per-query attribution; warehouse load for the last 14 days only, for the warehouses this role can see; the name stands in for the warehouse id
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
m AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         DATE(start_time) AS usage_date,
         SUM(credits_used_compute) AS compute_credits,
         COUNT_IF(credits_used_compute > 0) AS metered_hours,
         -- Only hours older than the 8 h attribution lag with a non-NULL split count as idle evidence.
         SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL, credits_used_compute, 0)) AS attributed_compute_credits,
         SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_attributed_compute_queries, 0)) AS attributed_query_credits,
         COUNT_IF(credits_used_compute > 0 AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL) AS attributed_hours
  FROM __SHIM_WAREHOUSE_METERING_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), DATE(start_time)
  HAVING SUM(credits_used_compute) > 0
),
ld AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         DATE(start_time) AS usage_date,
         SUM(IFF(avg_running > 0, DATEDIFF(second, start_time, end_time), 0)) / 3600 AS running_hours,
         SUM(IFF(avg_queued_load > 0, DATEDIFF(second, start_time, end_time), 0)) / 3600 AS queued_hours,
         SUM(IFF(avg_queued_provisioning > 0, DATEDIFF(second, start_time, end_time), 0)) / 3600 AS provisioning_hours,
         SUM(avg_queued_load * DATEDIFF(second, start_time, end_time)) / 3600 AS queued_query_hours
  FROM __SHIM_WAREHOUSE_LOAD_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), DATE(start_time)
),
-- Outer, so a day with load but no metering row yet (lag) is kept.
j AS (
  SELECT COALESCE(m.warehouse_id, l.warehouse_id) AS warehouse_id,
         COALESCE(m.warehouse_name, l.warehouse_name) AS warehouse_name,
         COALESCE(m.usage_date, l.usage_date) AS usage_date,
         m.compute_credits, m.metered_hours, m.attributed_compute_credits, m.attributed_query_credits,
         COALESCE(m.attributed_hours, 0) AS attributed_hours,
         l.running_hours, l.queued_hours, l.provisioning_hours, l.queued_query_hours
  FROM m FULL OUTER JOIN ld l ON l.warehouse_id = m.warehouse_id AND l.usage_date = m.usage_date
),
s AS (
  SELECT j.*, c.warehouse_size, c.credits_per_hour,
         j.compute_credits / NULLIF(c.credits_per_hour, 0) AS up_hours,
         IFF(j.attributed_hours > 0, GREATEST(j.attributed_compute_credits - j.attributed_query_credits, 0), NULL)
           / NULLIF(c.credits_per_hour, 0) AS idle_hours
  FROM j LEFT JOIN warehouse_config c ON c.warehouse_name = j.warehouse_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date, warehouse_id, warehouse_name,
       warehouse_size, metered_hours, compute_credits,
       ROUND(up_hours, 3) AS up_hours,
       ROUND(GREATEST(up_hours - idle_hours, 0), 3) AS busy_hours,
       ROUND(idle_hours, 3) AS idle_hours,
       ROUND(COALESCE(queued_hours, 0), 3) AS queued_hours,
       ROUND(COALESCE(provisioning_hours, 0), 3) AS provisioning_hours,
       ROUND(queued_query_hours, 3) AS queued_query_hours,
       ROUND(running_hours, 3) AS running_hours,
       compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN compute_credits IS NULL THEN NULL
            WHEN credits_per_hour IS NULL THEN 'unknown_size'
            WHEN attributed_hours = 0 THEN 'no_query_attribution' END AS not_assessed_reason
FROM s
ORDER BY warehouse_id, usage_date
