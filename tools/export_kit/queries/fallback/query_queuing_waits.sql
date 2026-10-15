-- query_id: query_queuing_waits
-- reads: INFORMATION_SCHEMA.QUERY_HISTORY (table function)
-- fallback_note: last 7 days at most, only the queries this role can see
-- Same columns as checks/query_queuing_waits.sql; the warehouse name stands in for its id.
WITH -- The INFORMATION_SCHEMA fallback's query feed, shared by the fallback checks: the result of
-- common/is_query_history_feed.sql, which the export runs once before the checks.
is_query_history AS (
  SELECT * FROM TABLE(RESULT_SCAN(__IS_QUERY_HISTORY_ID__))
),
h AS (
  SELECT DATE(start_time) AS day, HOUR(start_time) AS hour_of_day, DAYOFWEEKISO(start_time) AS day_of_week,
         warehouse_id,
         COUNT(*) AS query_count,
         COUNT_IF(queued_overload_time > 0) AS queued_at_capacity_count,
         COUNT_IF(queued_provisioning_time > 0) AS waited_for_compute_count,
         SUM(queued_overload_time) AS waiting_at_capacity_ms_sum,
         SUM(queued_provisioning_time) AS waiting_for_compute_ms_sum,
         SUM(total_elapsed_time) AS total_duration_ms_sum
  FROM is_query_history
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_name IS NOT NULL
  GROUP BY 1, 2, 3, 4
),
d AS (
  SELECT h.*,
         SUM(waiting_at_capacity_ms_sum) OVER (PARTITION BY day, warehouse_id) AS day_capacity_ms,
         SUM(waiting_for_compute_ms_sum) OVER (PARTITION BY day, warehouse_id) AS day_compute_ms
  FROM h
)
SELECT :period_days AS window_days, day, hour_of_day, day_of_week, __ACCOUNT_ID__ AS account_id,
       'WAREHOUSE' AS compute_type, warehouse_id,
       query_count, queued_at_capacity_count, waited_for_compute_count,
       waiting_at_capacity_ms_sum, waiting_for_compute_ms_sum, total_duration_ms_sum,
       IFF((day_capacity_ms IS NULL OR day_compute_ms IS NULL)
             AND COALESCE(day_capacity_ms, 0) + COALESCE(day_compute_ms, 0) < :warn_queue_secs * 1000,
           'no_queue_time_recorded', NULL) AS not_assessed_reason,
       CASE
         WHEN COALESCE(day_capacity_ms, 0) + COALESCE(day_compute_ms, 0) >= :crit_queue_secs * 1000 THEN 'CRITICAL'
         WHEN COALESCE(day_capacity_ms, 0) + COALESCE(day_compute_ms, 0) >= :warn_queue_secs * 1000 THEN 'WARN'
         WHEN day_capacity_ms IS NULL OR day_compute_ms IS NULL THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM d
ORDER BY COALESCE(day_capacity_ms, 0) + COALESCE(day_compute_ms, 0) DESC, day, warehouse_id, hour_of_day
