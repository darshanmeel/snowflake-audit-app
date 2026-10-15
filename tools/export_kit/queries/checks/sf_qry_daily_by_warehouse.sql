-- query_id: sf_qry_daily_by_warehouse
-- title: Query load per warehouse per day
-- domain: performance   tier: standard
-- entity: warehouses = warehouse_id
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- empty_if: role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Reference feed for trend charts; no bands.
-- read_this: one row = one warehouse and one UTC day in the window; a quiet day is kept with queries = 0.
--   Every warehouse that ran a query in the window is listed. queries and failed_queries are statement
--   counts; times are seconds (total_elapsed_s summed, avg_elapsed_s and p95_elapsed_s per query);
--   queued_* are seconds spent queued (overload = warehouse full, provisioning = resume or resize). Bytes
--   are raw bytes. cache_scan_pct is the bytes-weighted share of scanned data read from the warehouse
--   cache. warehouse_size is the last size the day's queries ran on (NULL when none recorded one).
-- healthy: n/a - reference feed for the Trend charts, every row reads OK.
-- investigate_if: n/a - reference feed. Rising queued_overload_s or bytes_spilled_remote on one warehouse
--   is the trend worth a look.
-- actions: n/a - reference feed, nothing to act on
-- next: query_queuing_waits
-- caveats: only statements that ran on a warehouse, the same scope as the queue-wait check, so query counts agree.
--   Days are UTC (DATE of start_time). p95_elapsed_s is approximate (APPROX_PERCENTILE). QUERY_HISTORY lags up
--   to 45 minutes and keeps 365 days, so the last day can be partial. warehouse_name is the latest name
--   the warehouse had in the window. Rows run busiest warehouse first, so a row cap drops whole quiet ones.
WITH q AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name, warehouse_size, start_time,
         DATE(start_time) AS usage_date,
         UPPER(execution_status) IN ('FAIL', 'INCIDENT') AS is_failed,
         COALESCE(total_elapsed_time, 0) / 1000 AS elapsed_s,
         COALESCE(queued_overload_time, 0) / 1000 AS q_over_s,
         COALESCE(queued_provisioning_time, 0) / 1000 AS q_prov_s,
         COALESCE(bytes_spilled_to_local_storage, 0) AS spill_local,
         COALESCE(bytes_spilled_to_remote_storage, 0) AS spill_remote,
         COALESCE(bytes_scanned, 0) AS scanned,
         COALESCE(bytes_scanned, 0) * COALESCE(percentage_scanned_from_cache, 0) AS scanned_cache
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
),
wh AS (
  -- one name per warehouse, so a rename mid-window does not split its series
  SELECT warehouse_id, MAX_BY(warehouse_name, start_time) AS warehouse_name, COUNT(*) AS wh_queries
  FROM q GROUP BY warehouse_id
),
days AS (
  SELECT DATEADD(day, -ROW_NUMBER() OVER (ORDER BY SEQ4()), __AS_OF_DATE__) AS usage_date
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
  QUALIFY usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__)
),
d AS (
  SELECT warehouse_id, usage_date,
         -- NULL key skips statements that carry no size (e.g. metadata-only)
         MAX_BY(warehouse_size, IFF(warehouse_size IS NULL, NULL, start_time)) AS warehouse_size,
         COUNT(*) AS queries,
         COUNT_IF(is_failed) AS failed_queries,
         SUM(elapsed_s) AS total_elapsed_s,
         AVG(elapsed_s) AS avg_elapsed_s,
         APPROX_PERCENTILE(elapsed_s, 0.95) AS p95_elapsed_s,
         SUM(q_over_s) AS queued_overload_s,
         SUM(q_prov_s) AS queued_provisioning_s,
         SUM(spill_local) AS bytes_spilled_local,
         SUM(spill_remote) AS bytes_spilled_remote,
         COUNT_IF(spill_remote > 0) AS queries_spilling_remote,
         SUM(scanned) AS bytes_scanned,
         100 * SUM(scanned_cache) / NULLIF(SUM(scanned), 0) AS cache_scan_pct
  FROM q
  GROUP BY warehouse_id, usage_date
)
-- every warehouse x every day, so a quiet day reads 0, not a gap
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, g.usage_date,
       w.warehouse_id, w.warehouse_name, d.warehouse_size,
       COALESCE(d.queries, 0) AS queries,
       COALESCE(d.failed_queries, 0) AS failed_queries,
       COALESCE(d.total_elapsed_s, 0) AS total_elapsed_s,
       d.avg_elapsed_s, d.p95_elapsed_s,
       COALESCE(d.queued_overload_s, 0) AS queued_overload_s,
       COALESCE(d.queued_provisioning_s, 0) AS queued_provisioning_s,
       COALESCE(d.bytes_spilled_local, 0) AS bytes_spilled_local,
       COALESCE(d.bytes_spilled_remote, 0) AS bytes_spilled_remote,
       COALESCE(d.queries_spilling_remote, 0) AS queries_spilling_remote,
       d.cache_scan_pct,
       COALESCE(d.bytes_scanned, 0) AS bytes_scanned,
       'OK' AS status,
       CAST(NULL AS VARCHAR) AS not_assessed_reason
FROM wh w
CROSS JOIN days g
LEFT JOIN d ON d.warehouse_id = w.warehouse_id AND d.usage_date = g.usage_date
-- busiest first: the export's row cap then cuts whole quiet warehouses, never days out of a series
ORDER BY w.wh_queries DESC, w.warehouse_id, g.usage_date
