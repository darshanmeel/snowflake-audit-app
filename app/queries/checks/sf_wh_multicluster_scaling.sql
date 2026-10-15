-- query_id: sf_wh_multicluster_scaling
-- title: Multi-cluster settings versus clusters actually used
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :queued_load_min (default 0.1) queued load min: value this check uses; :warn_queued_pct
--   (default 5) queued pct: at or above this the row reads WARN; :crit_queued_pct (default 20) queued
--   pct: at or above this the row reads CRITICAL; :low_extra_cluster_pct (default 5) low extra cluster
--   pct: value this check uses
-- not_assessed_reasons: no_queries: no query ran on the warehouse in the window; no_load_history:
--   queries ran but WAREHOUSE_LOAD_HISTORY has no rows for it in the window, so queueing is unknown
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. min/max_clusters and scaling_policy are the current settings;
--   max_cluster_seen is the highest cluster number any query or scaling event used. queued_pct = queued
--   load as a share of running plus queued load; extra_cluster_query_pct = share of queries run on
--   cluster 2+.
-- healthy: status = OK when queries rarely queue and min_clusters is 1
-- investigate_if: WARN when queued_pct >= warn_queued_pct, min_clusters > 1, or ECONOMY policy queues;
--   CRITICAL when queued_pct >= crit_queued_pct
-- actions: 1) SET MIN_CLUSTER_COUNT = 1 unless a fixed floor is needed, extra minimum clusters bill
--   whenever the warehouse runs (config); 2) at the ceiling and queued, raise MAX_CLUSTER_COUNT or move
--   a workload out (config, spend); 3) ECONOMY and queued, switch to STANDARD; STANDARD with rare
--   bursts, try ECONOMY (config)
-- next: none
-- caveats: multi-cluster needs Enterprise edition. A max never reached costs nothing; it is a cap, and
--   a very high cap is only a runaway-spend guard question. Load history is sampled in 5-minute
--   intervals.
WITH __INCLUDE_warehouse_config__,
ld AS (
  SELECT warehouse_name,
         SUM(avg_running * DATEDIFF(second, start_time, end_time)) / 3600 AS running_query_hours,
         SUM(avg_queued_load * DATEDIFF(second, start_time, end_time)) / 3600 AS queued_query_hours,
         COUNT(DISTINCT IFF(avg_queued_load >= :queued_load_min, DATE_TRUNC('hour', start_time), NULL)) AS queued_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
ev AS (
  SELECT warehouse_name, MAX(cluster_number) AS max_event_cluster,
         -- a spin-up writes a STARTED and a COMPLETED row; count it once
         COUNT_IF(event_name = 'RESUME_CLUSTER' AND event_reason = 'MULTICLUSTER_SPINUP'
                  AND COALESCE(event_state, 'STARTED') = 'STARTED') AS spinups
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
  GROUP BY 1
),
qh AS (
  SELECT warehouse_name, COUNT(*) AS query_count, MAX(cluster_number) AS max_query_cluster,
         COUNT_IF(cluster_number > 1) AS extra_cluster_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
  GROUP BY 1
),
m AS (
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
j AS (
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_size, UPPER(c.scaling_policy) AS scaling_policy,
         COALESCE(c.min_clusters, 1) AS min_clusters, COALESCE(c.max_clusters, 1) AS max_clusters,
         COALESCE(qh.query_count, 0) AS query_count, qh.extra_cluster_queries, e.spinups,
         GREATEST(COALESCE(qh.max_query_cluster, 0), COALESCE(e.max_event_cluster, 0)) AS max_cluster_seen,
         l.running_query_hours, l.queued_query_hours, l.queued_hours, m.compute_credits,
         100 * l.queued_query_hours / NULLIF(l.running_query_hours + l.queued_query_hours, 0) AS queued_pct,
         100 * qh.extra_cluster_queries / NULLIF(qh.query_count, 0) AS extra_cluster_query_pct
  FROM warehouse_config c
  LEFT JOIN ld l ON l.warehouse_name = c.warehouse_name
  LEFT JOIN ev e ON e.warehouse_name = c.warehouse_name
  LEFT JOIN qh ON qh.warehouse_name = c.warehouse_name
  LEFT JOIN m ON m.warehouse_name = c.warehouse_name
),
h AS (
  SELECT j.*,
         CASE
           WHEN max_clusters = 1 AND queued_pct >= :warn_queued_pct THEN 'ENABLE_MULTI_CLUSTER'
           WHEN max_clusters > 1 AND max_cluster_seen >= max_clusters AND queued_pct >= :warn_queued_pct THEN 'RAISE_MAX_CLUSTERS'
           WHEN scaling_policy = 'ECONOMY' AND queued_pct >= :warn_queued_pct THEN 'SWITCH_TO_STANDARD'
           WHEN min_clusters > 1 THEN 'LOWER_MIN_CLUSTERS'
           WHEN max_clusters > 1 AND scaling_policy = 'STANDARD' AND COALESCE(queued_pct, 0) < 1
                AND extra_cluster_query_pct < :low_extra_cluster_pct AND extra_cluster_queries > 0 THEN 'TRY_ECONOMY'
           WHEN max_clusters > 1 AND max_cluster_seen < max_clusters THEN 'MAX_NEVER_REACHED'
           ELSE 'NONE'
         END AS scaling_hint
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, scaling_policy, CAST(min_clusters AS INTEGER) AS min_clusters,
       CAST(max_clusters AS INTEGER) AS max_clusters, CAST(max_cluster_seen AS INTEGER) AS max_cluster_seen,
       spinups, query_count, extra_cluster_queries, extra_cluster_query_pct,
       running_query_hours, queued_query_hours, queued_hours, queued_pct,
       compute_credits, compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       scaling_hint,
       IFF(query_count = 0, 'no_queries', IFF(running_query_hours IS NULL, 'no_load_history', NULL)) AS not_assessed_reason,
       CASE
         WHEN query_count = 0 THEN 'NOT_ASSESSED'
         WHEN running_query_hours IS NULL THEN 'NOT_ASSESSED'
         WHEN queued_pct >= :crit_queued_pct THEN 'CRITICAL'
         WHEN scaling_hint IN ('ENABLE_MULTI_CLUSTER', 'RAISE_MAX_CLUSTERS', 'SWITCH_TO_STANDARD', 'LOWER_MIN_CLUSTERS') THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM h
ORDER BY IFF(status = 'CRITICAL', 0, IFF(status = 'WARN', 1, IFF(status = 'NOT_ASSESSED', 3, 2))), queued_pct DESC NULLS LAST, compute_credits DESC NULLS LAST
