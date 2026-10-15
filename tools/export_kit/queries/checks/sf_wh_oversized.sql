-- query_id: sf_wh_oversized
-- title: Large warehouses that mostly run small queries
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_credits_per_hour (default 8) credits per hour: least a row needs before it can flag;
--   :small_scan_gb (default 1) small scan gb: value this check uses; :small_exec_s (default 10) small
--   exec s: value this check uses; :min_queries (default 200) queries: least a row needs before it can
--   flag; :warn_small_pct (default 90) small pct: at or above this the row reads WARN; :crit_small_pct
--   (default 97) small pct: at or above this the row reads CRITICAL; :warn_saving_credits (default 50)
--   saving credits: at or above this the row reads WARN; :crit_saving_credits (default 500) saving
--   credits: at or above this the row reads CRITICAL; :max_spilling_pct (default 5) spilling pct: at or
--   above this the warehouse needs its size and reads OK
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse at its current size. small_query_pct = share of its successful
--   queries at that size that scanned under small_scan_gb, ran under small_exec_s and did not spill.
--   est_saving_credits = half its compute credits at this size (never more than its spend), what one size
--   down saves if run times stay flat; 0 when the warehouse spills (spill_reason says why).
-- healthy: status = OK when the warehouse is below Large (min_credits_per_hour), its queries are not
--   mostly small, or it spills: any remote spill, or max_spilling_pct of its queries spill to disk (then
--   it is short of memory, the undersized check's case, and a smaller size would spill more)
-- investigate_if: WARN when small_query_pct >= warn_small_pct and the saving >= warn_saving_credits;
--   CRITICAL when small_query_pct >= crit_small_pct and the saving >= crit_saving_credits
-- actions: 1) ALTER WAREHOUSE ... SET WAREHOUSE_SIZE = suggested_size and watch p90 run time for a week
--   (config); 2) move the few heavy jobs (p90 columns) to their own warehouse so the shared one can
--   shrink (config)
-- next: none
-- caveats: the saving assumes small queries keep their run time one size down, usually true for
--   sub-second and few-GB queries but not guaranteed. Credits cover the whole window even if the size
--   changed in it. Snowpark-optimized warehouses bill more than the standard rate used here.
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
), -- Standard credits per hour by warehouse size, keyed by UPPER(REPLACE(size, '-', '')) so sizes from
-- SHOW WAREHOUSES and QUERY_HISTORY both match; smaller_size is the one-step-down target for resizing.
sf_wh_size_rate AS (
  SELECT column1 AS size_key, column2 AS size_rank, column3 AS credits_per_hour,
         column4 AS smaller_size, column5 AS larger_size
  FROM VALUES
    ('XSMALL', 1, 1, 'none', 'Small'), ('SMALL', 2, 2, 'X-Small', 'Medium'),
    ('MEDIUM', 3, 4, 'Small', 'Large'), ('LARGE', 4, 8, 'Medium', 'X-Large'),
    ('XLARGE', 5, 16, 'Large', '2X-Large'), ('2XLARGE', 6, 32, 'X-Large', '3X-Large'),
    ('XXLARGE', 6, 32, 'X-Large', '3X-Large'), ('X2LARGE', 6, 32, 'X-Large', '3X-Large'),
    ('3XLARGE', 7, 64, '2X-Large', '4X-Large'), ('XXXLARGE', 7, 64, '2X-Large', '4X-Large'),
    ('X3LARGE', 7, 64, '2X-Large', '4X-Large'), ('4XLARGE', 8, 128, '3X-Large', '5X-Large'),
    ('X4LARGE', 8, 128, '3X-Large', '5X-Large'), ('5XLARGE', 9, 256, '4X-Large', '6X-Large'),
    ('X5LARGE', 9, 256, '4X-Large', '6X-Large'), ('6XLARGE', 10, 512, '5X-Large', 'none'),
    ('X6LARGE', 10, 512, '5X-Large', 'none')
),
q AS (
  SELECT warehouse_name, UPPER(REPLACE(warehouse_size, '-', '')) AS size_key,
         COUNT(*) AS query_count,
         -- small = cheap enough that half the compute would still finish it quickly
         COUNT_IF(bytes_scanned < :small_scan_gb * POWER(1024, 3)
                  AND execution_time < :small_exec_s * 1000
                  AND bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage = 0) AS small_query_count,
         COUNT_IF(bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage > 0) AS spilling_query_count,
         COUNT_IF(bytes_spilled_to_remote_storage > 0) AS remote_spill_query_count,
         APPROX_PERCENTILE(execution_time / 1000, 0.5) AS p50_exec_s,
         APPROX_PERCENTILE(execution_time / 1000, 0.9) AS p90_exec_s,
         APPROX_PERCENTILE(bytes_scanned / POWER(1024, 3), 0.9) AS p90_scan_gb,
         MAX(bytes_scanned) / POWER(1024, 3) AS max_scan_gb
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL AND execution_status = 'SUCCESS' AND execution_time > 0
  GROUP BY 1, 2
),
m AS (
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
j AS (
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_type, c.warehouse_size,
         CAST(c.max_clusters AS INTEGER) AS max_clusters, c.credits_per_hour, r.credits_per_hour AS size_rate,
         r.smaller_size,
         COALESCE(q.query_count, 0) AS query_count, COALESCE(q.small_query_count, 0) AS small_query_count,
         COALESCE(q.spilling_query_count, 0) AS spilling_query_count,
         COALESCE(q.remote_spill_query_count, 0) AS remote_spill_query_count,
         q.p50_exec_s, q.p90_exec_s, q.p90_scan_gb, q.max_scan_gb,
         COALESCE(m.compute_credits, 0) AS compute_credits,
         -- credits at the current size: the warehouse may have been resized inside the window, so the
         -- window's credits are split by the share of its statements that ran at this size
         COALESCE(m.compute_credits, 0) * COALESCE(q.query_count, 0) / NULLIF(qa.all_queries, 0) AS current_size_credits,
         100 * q.small_query_count / NULLIF(q.query_count, 0) AS small_query_pct,
         100 * q.spilling_query_count / NULLIF(q.query_count, 0) AS spilling_query_pct
  FROM warehouse_config c
  LEFT JOIN sf_wh_size_rate r ON r.size_key = UPPER(REPLACE(c.warehouse_size, '-', ''))
  LEFT JOIN q ON q.warehouse_name = c.warehouse_name AND q.size_key = r.size_key
  LEFT JOIN (SELECT warehouse_name, SUM(query_count) AS all_queries FROM q GROUP BY 1) qa
    ON qa.warehouse_name = c.warehouse_name
  LEFT JOIN m ON m.warehouse_name = c.warehouse_name
),
sp AS (
  -- short of memory: a smaller size would spill more, so there is no size-down saving
  SELECT j.*,
         CASE WHEN remote_spill_query_count > 0 THEN 'remote spill in ' || remote_spill_query_count || ' queries'
              WHEN spilling_query_pct >= :max_spilling_pct THEN ROUND(spilling_query_pct, 1) || '% of queries spill to disk'
         END AS spill_reason
  FROM j
),
s AS (
  SELECT sp.*,
         -- one size down halves the hourly rate (every generation doubles per size); never more than
         -- the warehouse's own compute credits in the window
         IFF(size_rate IS NULL OR credits_per_hour IS NULL, NULL,
             IFF(size_rate >= :min_credits_per_hour AND spill_reason IS NULL,
                 LEAST(COALESCE(current_size_credits, 0) / 2, compute_credits), 0)) AS est_saving_credits
  FROM sp
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_type, warehouse_size, max_clusters, credits_per_hour,
       query_count, small_query_count, small_query_pct, spilling_query_count, remote_spill_query_count,
       spill_reason,
       p50_exec_s, p90_exec_s, p90_scan_gb, max_scan_gb,
       compute_credits, compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list,
       IFF(size_rate >= :min_credits_per_hour AND spill_reason IS NULL AND credits_per_hour IS NOT NULL, smaller_size, NULL) AS suggested_size,
       est_saving_credits, est_saving_credits * __CREDIT_PRICE__ AS est_saving_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       -- adaptive warehouses (credits_per_hour NULL) have no fixed rate to size down from
       CASE WHEN size_rate IS NULL OR credits_per_hour IS NULL THEN 'unknown_size'
            WHEN query_count < :min_queries THEN 'too_few_queries' END AS not_assessed_reason,
       CASE
         WHEN size_rate IS NULL OR credits_per_hour IS NULL OR query_count < :min_queries THEN 'NOT_ASSESSED'
         WHEN size_rate < :min_credits_per_hour OR spill_reason IS NOT NULL THEN 'OK'
         WHEN small_query_pct >= :crit_small_pct AND est_saving_credits >= :crit_saving_credits THEN 'CRITICAL'
         WHEN small_query_pct >= :warn_small_pct AND est_saving_credits >= :warn_saving_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY est_saving_credits DESC NULLS LAST, warehouse_name
