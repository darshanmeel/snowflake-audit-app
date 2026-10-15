-- query_id: query_queuing_waits
-- title: Queries queued for capacity or compute provisioning
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_queue_secs (default 60) combined queued-for-capacity + waiting-for-compute seconds per
--   day+warehouse that flags WARN; :crit_queue_secs (default 600) ... that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a day + hour-of-day (UTC) + warehouse that ran queries; day_of_week is ISO (1 = Monday).
--   status is judged on the whole day + warehouse and repeated on its hour rows. The columns
--   that matter are waiting_at_capacity_ms_sum (queued because the warehouse was already at max
--   concurrency/scale) and waiting_for_compute_ms_sum (compute was still provisioning - cold start). A
--   warehouse that shows up here repeatedly on the same day-of-week/hour pattern is under-sized or
--   under-scheduled for its load, not just unlucky once.
-- healthy: waiting_at_capacity_ms_sum + waiting_for_compute_ms_sum below :warn_queue_secs seconds/day
--   per warehouse (field heuristic - tune :warn_queue_secs for your account).
-- investigate_if: combined wait at/above :warn_queue_secs seconds (WARN) or :crit_queue_secs seconds
--   (CRITICAL) - field heuristic; waits that recur on the same warehouse are the real signal, not a
--   single spike.
-- actions: 1) check whether the wait clusters at specific hours before changing anything, e.g. against
--   query_workload_mix_hours (free); 2) raise the warehouse's max clusters/scaling limit, or keep it
--   warm through the busy window with a longer auto-stop (config); 3) split the workload onto a second
--   warehouse, or size up the existing one, if concurrency is structurally too high for one warehouse
--   (spend).
-- next: none
-- caveats: Snowflake version: waiting at capacity = queued_overload_time, waiting for compute =
--   queued_provisioning_time. queued_repair_time (a rare node repair) is not counted.
WITH h AS (
  SELECT DATE(start_time) AS day, HOUR(start_time) AS hour_of_day, DAYOFWEEKISO(start_time) AS day_of_week,
         TO_VARCHAR(warehouse_id) AS warehouse_id,
         COUNT(*) AS query_count,
         COUNT_IF(queued_overload_time > 0) AS queued_at_capacity_count,
         COUNT_IF(queued_provisioning_time > 0) AS waited_for_compute_count,
         SUM(queued_overload_time) AS waiting_at_capacity_ms_sum,
         SUM(queued_provisioning_time) AS waiting_for_compute_ms_sum,
         SUM(total_elapsed_time) AS total_duration_ms_sum
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
  GROUP BY 1, 2, 3, 4
),
-- The status is judged on the whole day + warehouse and repeated on its hour rows.
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
