-- query_id: sf_wh_undersized
-- title: Warehouses too small for their queries (remote spill, long runs)
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SHOW
--   WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_queries (default 20) queries: least a row needs before it can flag;
--   :warn_remote_spill_queries (default 5) remote spill queries: at or above this the row reads WARN;
--   :crit_remote_spill_gb (default 100) remote spill gb: at or above this the row reads CRITICAL;
--   :warn_spill_time_pct (default 20) spill time pct: at or above this the row reads WARN;
--   :crit_spill_time_pct (default 50) spill time pct: at or above this the row reads CRITICAL;
--   :long_exec_min (default 30) long exec min: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse at its current size. Remote spill means the query ran out of
--   memory and local disk and wrote to object storage, the slowest path. spill_time_pct = share of
--   execution time spent in queries that spilled at all. spilling_credits = attributed credits of those
--   queries.
-- healthy: status = OK when few queries spill remotely and spilling queries are a small share of run
--   time
-- investigate_if: WARN when remote_spill_queries >= warn_remote_spill_queries or spill_time_pct >=
--   warn_spill_time_pct; CRITICAL when remote_spill_gb >= crit_remote_spill_gb or spill_time_pct >=
--   crit_spill_time_pct
-- actions: 1) tune the top spilling statements first, see sf_query_remote_spill (free); 2) size up to
--   suggested_size; a query that stops spilling often runs over twice as fast, so the bigger size can
--   cost the same or less (config); 3) move the heavy jobs to their own larger warehouse (config)
-- next: none
-- caveats: sized by the size at query time matching the current size. Credits from
--   QUERY_ATTRIBUTION_HISTORY exclude idle time and queries under about 100 ms, and lag up to 8 hours.
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
qh AS (
  SELECT query_id, warehouse_name, UPPER(REPLACE(warehouse_size, '-', '')) AS size_key,
         execution_time, bytes_spilled_to_local_storage AS local_b, bytes_spilled_to_remote_storage AS remote_b
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL AND execution_time > 0
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
q AS (
  SELECT qh.warehouse_name, qh.size_key,
         COUNT(*) AS query_count,
         COUNT_IF(remote_b > 0) AS remote_spill_queries,
         COUNT_IF(local_b + remote_b > 0) AS spilling_queries,
         SUM(remote_b) / POWER(1024, 3) AS remote_spill_gb,
         SUM(local_b) / POWER(1024, 3) AS local_spill_gb,
         SUM(IFF(local_b + remote_b > 0, execution_time, 0)) / 1000 AS spill_exec_s,
         SUM(execution_time) / 1000 AS exec_s,
         COUNT_IF(execution_time >= :long_exec_min * 60000) AS long_queries,
         APPROX_PERCENTILE(execution_time / 1000, 0.95) AS p95_exec_s,
         SUM(IFF(local_b + remote_b > 0, a.credits, 0)) AS spilling_credits,
         SUM(a.credits) AS attributed_credits
  FROM qh LEFT JOIN attr a ON a.query_id = qh.query_id
  GROUP BY 1, 2
),
j AS (
  -- LEFT joins keep warehouses with no queries at this size or no known size, as NOT_ASSESSED
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_type, c.warehouse_size, c.credits_per_hour,
         r.size_key, r.larger_size, COALESCE(q.query_count, 0) AS query_count,
         q.remote_spill_queries, q.spilling_queries, q.remote_spill_gb, q.local_spill_gb, q.spill_exec_s,
         q.exec_s, q.long_queries, q.p95_exec_s, q.spilling_credits, q.attributed_credits,
         100 * q.spill_exec_s / NULLIF(q.exec_s, 0) AS spill_time_pct
  FROM warehouse_config c
  LEFT JOIN sf_wh_size_rate r ON r.size_key = UPPER(REPLACE(c.warehouse_size, '-', ''))
  LEFT JOIN q ON q.warehouse_name = c.warehouse_name AND q.size_key = r.size_key
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_type, warehouse_size, credits_per_hour, query_count,
       spilling_queries, remote_spill_queries, remote_spill_gb, local_spill_gb, spill_time_pct,
       long_queries, p95_exec_s, exec_s AS execution_s_sum,
       attributed_credits, spilling_credits,
       spilling_credits * __CREDIT_PRICE__ AS est_spilling_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       -- an unjudged warehouse (adaptive, unknown size, too few queries) gets no suggestion
       IFF(size_key IS NULL OR credits_per_hour IS NULL OR query_count < :min_queries, NULL, larger_size) AS suggested_size,
       CASE WHEN size_key IS NULL OR credits_per_hour IS NULL THEN 'unknown_size'
            WHEN query_count < :min_queries THEN 'too_few_queries' END AS not_assessed_reason,
       CASE
         WHEN size_key IS NULL OR credits_per_hour IS NULL OR query_count < :min_queries THEN 'NOT_ASSESSED'
         WHEN remote_spill_gb >= :crit_remote_spill_gb OR spill_time_pct >= :crit_spill_time_pct THEN 'CRITICAL'
         WHEN remote_spill_queries >= :warn_remote_spill_queries OR spill_time_pct >= :warn_spill_time_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY remote_spill_gb DESC NULLS LAST, spill_time_pct DESC NULLS LAST
