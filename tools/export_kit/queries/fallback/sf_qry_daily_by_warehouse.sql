-- query_id: sf_qry_daily_by_warehouse
-- reads: INFORMATION_SCHEMA.QUERY_HISTORY (table function)
-- fallback_note: last 7 days at most, only the queries this role can see; no spill or cache figures
-- Same columns as checks/sf_qry_daily_by_warehouse.sql. The warehouse name stands in for its id;
-- spill and cache columns are NULL (the table function does not return them).
WITH -- The INFORMATION_SCHEMA fallback's query feed, shared by the fallback checks: the slices of
-- common/is_query_history_feed.sql that the export ran before the checks, one row per query id.
is_query_history AS (
  SELECT * FROM (__IS_QUERY_HISTORY_SCANS__)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY end_time DESC) = 1
),
q AS (
  SELECT warehouse_id, warehouse_name, warehouse_size, start_time,
         DATE(start_time) AS usage_date,
         UPPER(execution_status) IN ('FAIL', 'INCIDENT', 'FAILED_WITH_ERROR', 'FAILED_WITH_INCIDENT') AS is_failed,
         COALESCE(total_elapsed_time, 0) / 1000 AS elapsed_s,
         COALESCE(queued_overload_time, 0) / 1000 AS q_over_s,
         COALESCE(queued_provisioning_time, 0) / 1000 AS q_prov_s,
         COALESCE(bytes_scanned, 0) AS scanned
  FROM is_query_history
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_name IS NOT NULL
),
wh AS (
  SELECT warehouse_id, MAX_BY(warehouse_name, start_time) AS warehouse_name, COUNT(*) AS wh_queries
  FROM q GROUP BY warehouse_id
),
-- only the days the table function can reach, so days before it never read as quiet
days AS (
  SELECT DATEADD(day, -ROW_NUMBER() OVER (ORDER BY SEQ4()), __AS_OF_DATE__) AS usage_date
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
  QUALIFY usage_date >= GREATEST(DATEADD(day, -:period_days, __AS_OF_DATE__), DATEADD(day, -7, CURRENT_DATE()))
),
d AS (
  SELECT warehouse_id, usage_date,
         MAX_BY(warehouse_size, IFF(warehouse_size IS NULL, NULL, start_time)) AS warehouse_size,
         COUNT(*) AS queries,
         COUNT_IF(is_failed) AS failed_queries,
         SUM(elapsed_s) AS total_elapsed_s,
         AVG(elapsed_s) AS avg_elapsed_s,
         APPROX_PERCENTILE(elapsed_s, 0.95) AS p95_elapsed_s,
         SUM(q_over_s) AS queued_overload_s,
         SUM(q_prov_s) AS queued_provisioning_s,
         SUM(scanned) AS bytes_scanned
  FROM q
  GROUP BY warehouse_id, usage_date
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, g.usage_date,
       w.warehouse_id, w.warehouse_name, d.warehouse_size,
       COALESCE(d.queries, 0) AS queries,
       COALESCE(d.failed_queries, 0) AS failed_queries,
       COALESCE(d.total_elapsed_s, 0) AS total_elapsed_s,
       d.avg_elapsed_s, d.p95_elapsed_s,
       COALESCE(d.queued_overload_s, 0) AS queued_overload_s,
       COALESCE(d.queued_provisioning_s, 0) AS queued_provisioning_s,
       CAST(NULL AS NUMBER) AS bytes_spilled_local,
       CAST(NULL AS NUMBER) AS bytes_spilled_remote,
       CAST(NULL AS NUMBER) AS queries_spilling_remote,
       CAST(NULL AS DOUBLE) AS cache_scan_pct,
       COALESCE(d.bytes_scanned, 0) AS bytes_scanned,
       'OK' AS status,
       CAST(NULL AS VARCHAR) AS not_assessed_reason
FROM wh w
CROSS JOIN days g
LEFT JOIN d ON d.warehouse_id = w.warehouse_id AND d.usage_date = g.usage_date
ORDER BY w.wh_queries DESC, w.warehouse_id, g.usage_date
