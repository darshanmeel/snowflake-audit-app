-- query_id: query_warehouse_pressure
-- title: warehouse pressure - memory-bound (statements spill) or concurrency-bound (statements queue at
--   capacity), with the scaling lever for each
-- domain: performance   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY, SHOW
--   WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_queries (default 20) statements in the window below which a warehouse is NOT_ASSESSED;
--   :min_stmt_spill_mb (default 100) the local spill, in MB (10^6 bytes), one statement must reach to
--   count as a spilling statement in spill_time_pct and spilling_query_count (the GB columns and the
--   worst day still add every spilled byte); :warn_spill_time_pct (default 10) percent of the
--   warehouse's execution time spent in statements that spilled at least :min_stmt_spill_mb MB to local
--   disk that flags WARN (the 10 percent band query_costly_statements_grouped uses for one statement's share of
--   its warehouse); :crit_spill_time_pct (default 25) the same share that flags CRITICAL (its 25
--   percent band); :warn_spill_gb (default 1) the worst single day's local spill in GB for the
--   warehouse that flags WARN (the query_local_spillage thresholds, applied to the whole warehouse's
--   day); :crit_spill_gb (default 10) the same that flags CRITICAL; :warn_queue_time_pct (default 5)
--   percent of total statement time spent queued at capacity that flags WARN; :crit_queue_time_pct
--   (default 20) the same that flags CRITICAL; :top_n (default 100000) row cap - far above any
--   account's warehouse count, because this is a verdict per warehouse
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one warehouse with at least one statement in the window. The columns that
--   matter are pressure (MEMORY, CAPACITY, MEMORY_AND_CAPACITY or NONE), scaling_hint (the lever:
--   SCALE_UP, SCALE_OUT, KEEP_WARM, SCALE_UP_THEN_OUT, SCALE_UP_THEN_WARM or NONE) and
--   pressure_reason (the row's own numbers behind the verdict). Memory pressure is spill_time_pct -
--   the share of the warehouse's execution time spent in statements that spilled at least
--   :min_stmt_spill_mb MB to local disk - or spilled_local_gb_max_day, the worst single day's
--   spill; concurrency pressure is capacity_wait_pct, the share of total statement time spent
--   queued because the warehouse was at capacity. at_ceiling says whether "more clusters" is even
--   the knob: TRUE means the warehouse has no autoscale range (min_clusters >= max_clusters, so it
--   always runs at its maximum) or some warehouse_events row in the window showed max_clusters
--   running, FALSE means no event in the window showed max_clusters running (read as autoscale lag
--   - keep a cluster warm), NULL means unseen. cold_start_wait_pct is context only;
--   query_cache_coldstart is the cold-start finding.
-- healthy: pressure = NONE - spill_time_pct below :warn_spill_time_pct, the worst day's local spill
--   below :warn_spill_gb GB and capacity_wait_pct below :warn_queue_time_pct (field heuristic; every
--   threshold is a header param).
-- investigate_if: MEMORY - spill_time_pct at/above :warn_spill_time_pct (WARN) or :crit_spill_time_pct
--   (CRITICAL), or the worst day's local spill at/above :warn_spill_gb GB (WARN) or :crit_spill_gb GB
--   (CRITICAL): statements on this warehouse do not fit in its memory, so the lever is size; CAPACITY -
--   capacity_wait_pct at/above :warn_queue_time_pct (WARN) or :crit_queue_time_pct (CRITICAL):
--   statements queue because every cluster is busy, so the lever is clusters at the ceiling or a warm
--   cluster below it; MEMORY_AND_CAPACITY - both. status is the worse of the two bands (field
--   heuristic). NOT_ASSESSED (fewer than :min_queries statements) is not a pass: read
--   not_assessed_reason.
-- actions: 1) short of memory - find the spilling statements in query_local_spillage and cut what
--   they hold in memory: filter earlier, avoid exploding joins and large sorts; queueing - check with
--   query_workload_mix_hours whether it clusters at a few hours before changing the warehouse (free);
--   2) queueing below the cluster ceiling - raise min_clusters so a second cluster is already running
--   when the load arrives, or route the heaviest recurring shapes to their own warehouse (config);
--   3) short of memory - a larger warehouse size gives every statement more memory; queueing at the
--   ceiling - raise max_clusters, or a larger size if the queued statements are themselves heavy;
--   both - size first, then clusters (spend).
-- next: none
-- not_assessed_reasons: too_few_queries: too few statements ran on this warehouse in the window to
--   judge
-- caveats: Snowflake version: memory pressure = spill (local and remote); concurrency pressure =
--   queued_overload_time; cold start = queued_provisioning_time. Scaling events from
--   WAREHOUSE_EVENTS_HISTORY. warehouse_deleted is TRUE only when the warehouse's last create or drop
--   event is a drop; warehouse_not_visible is TRUE when it is not in SHOW WAREHOUSES and not dropped (the
--   role cannot see it: size, clusters and the ceiling are then unknown).
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
q AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         COUNT(*) AS query_count,
         COUNT_IF(execution_status = 'SUCCESS') AS finished_count,
         COUNT_IF(bytes_spilled_to_local_storage >= :min_stmt_spill_mb * 1000000) AS spilling_query_count,
         SUM(IFF(bytes_spilled_to_local_storage >= :min_stmt_spill_mb * 1000000, execution_time, 0)) AS spill_exec_ms,
         SUM(bytes_spilled_to_local_storage) / POWER(1024, 3) AS spilled_gb,
         SUM(bytes_scanned) / POWER(1024, 3) AS read_gb,
         COUNT_IF(queued_overload_time > 0) AS queued_at_capacity_count,
         SUM(queued_overload_time) / 1000 AS overload_s,
         COUNT_IF(queued_provisioning_time > 0) AS waited_for_compute_count,
         SUM(queued_provisioning_time) / 1000 AS provisioning_s,
         SUM(execution_time) / 1000 AS execution_s,
         SUM(total_elapsed_time) / 1000 AS total_s
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
  GROUP BY 1
),
daily_spill AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id,
         MAX(gb) AS spilled_gb_max_day
  FROM (
    SELECT warehouse_id, DATE(start_time) AS d,
           SUM(bytes_spilled_to_local_storage) / POWER(1024, 3) AS gb
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
      AND warehouse_id IS NOT NULL
    GROUP BY 1, 2
  )
  GROUP BY 1
),
ev AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id,
         COUNT_IF(event_name IN ('RESUME_CLUSTER', 'SUSPEND_CLUSTER')) AS scaling_events,
         MAX(cluster_number) AS max_cluster_seen
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
  GROUP BY 1
),
life AS (
  -- A warehouse is dropped only when its last create or drop event is a drop; no event = unknown.
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id,
         MAX_BY(event_name, timestamp) = 'DROP_WAREHOUSE' AS dropped
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE event_name IN ('CREATE_WAREHOUSE', 'DROP_WAREHOUSE')
  GROUP BY 1
),
j AS (
  SELECT q.*, d.spilled_gb_max_day, e.scaling_events, e.max_cluster_seen,
         c.warehouse_type, c.warehouse_size, c.min_clusters, c.max_clusters, c.auto_stop_minutes,
         -- not in SHOW WAREHOUSES: dropped only with a drop event, otherwise the role cannot see it
         CASE WHEN c.warehouse_name IS NOT NULL THEN FALSE WHEN l.dropped THEN TRUE END AS deleted,
         c.warehouse_name IS NULL AND COALESCE(NOT l.dropped, TRUE) AS not_visible,
         100 * q.spilling_query_count / NULLIF(q.query_count, 0) AS spill_query_pct,
         100 * q.spill_exec_ms / 1000 / NULLIF(q.execution_s, 0) AS spill_time_pct,
         100 * q.overload_s / NULLIF(q.total_s, 0) AS capacity_wait_pct,
         100 * q.provisioning_s / NULLIF(q.total_s, 0) AS cold_start_wait_pct
  FROM q
  LEFT JOIN daily_spill d ON d.warehouse_id = q.warehouse_id
  LEFT JOIN ev e ON e.warehouse_id = q.warehouse_id
  LEFT JOIN life l ON l.warehouse_id = q.warehouse_id
  LEFT JOIN warehouse_config c ON c.warehouse_name = q.warehouse_name
),
b AS (
  SELECT j.*,
         CASE WHEN max_clusters IS NULL THEN NULL
              WHEN min_clusters >= max_clusters THEN TRUE
              WHEN max_cluster_seen IS NULL THEN NULL
              ELSE max_cluster_seen >= max_clusters END AS at_ceiling,
         CASE WHEN spill_time_pct >= :crit_spill_time_pct OR spilled_gb_max_day >= :crit_spill_gb THEN 2
              WHEN spill_time_pct >= :warn_spill_time_pct OR spilled_gb_max_day >= :warn_spill_gb THEN 1
              ELSE 0 END AS mem_band,
         CASE WHEN capacity_wait_pct >= :crit_queue_time_pct THEN 2
              WHEN capacity_wait_pct >= :warn_queue_time_pct THEN 1
              ELSE 0 END AS cap_band
  FROM j
),
p AS (
  SELECT b.*,
         CASE WHEN mem_band > 0 AND cap_band > 0 THEN 'MEMORY_AND_CAPACITY'
              WHEN mem_band > 0 THEN 'MEMORY'
              WHEN cap_band > 0 THEN 'CAPACITY'
              ELSE 'NONE' END AS pressure
  FROM b
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id,
       'WAREHOUSE' AS compute_type, warehouse_type, warehouse_size,
       CAST(min_clusters AS INTEGER) AS min_clusters, CAST(max_clusters AS INTEGER) AS max_clusters,
       CAST(auto_stop_minutes AS INTEGER) AS auto_stop_minutes, deleted AS warehouse_deleted,
       not_visible AS warehouse_not_visible,
       query_count, finished_count, spilling_query_count, spill_query_pct, spill_time_pct,
       spilled_gb AS spilled_local_gb_sum, spilled_gb_max_day AS spilled_local_gb_max_day,
       read_gb AS read_gb_sum, CAST(NULL AS DOUBLE) AS shuffle_read_gb_sum,
       queued_at_capacity_count, capacity_wait_pct, overload_s AS waiting_at_capacity_s_sum,
       waited_for_compute_count, cold_start_wait_pct, provisioning_s AS waiting_for_compute_s_sum,
       execution_s AS execution_s_sum, total_s AS total_duration_s_sum,
       CAST(max_cluster_seen AS INTEGER) AS max_cluster_count_seen, scaling_events, at_ceiling,
       pressure,
       CASE pressure
         WHEN 'MEMORY' THEN 'SCALE_UP'
         WHEN 'CAPACITY' THEN IFF(at_ceiling = FALSE, 'KEEP_WARM', 'SCALE_OUT')
         WHEN 'MEMORY_AND_CAPACITY' THEN IFF(at_ceiling = FALSE, 'SCALE_UP_THEN_WARM', 'SCALE_UP_THEN_OUT')
         ELSE 'NONE'
       END AS scaling_hint,
       ROUND(COALESCE(spill_time_pct, 0)) || '% of run time spilling, ' || ROUND(COALESCE(capacity_wait_pct, 0)) || '% queued at capacity' AS pressure_reason,
       IFF(query_count < :min_queries, 'too_few_queries', NULL) AS not_assessed_reason,
       CASE
         WHEN query_count < :min_queries THEN 'NOT_ASSESSED'
         WHEN GREATEST(mem_band, cap_band) = 2 THEN 'CRITICAL'
         WHEN GREATEST(mem_band, cap_band) = 1 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM p
QUALIFY ROW_NUMBER() OVER (ORDER BY total_s DESC) <= :top_n
ORDER BY total_s DESC
