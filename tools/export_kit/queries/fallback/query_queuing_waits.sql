-- query_id: query_queuing_waits
-- reads: INFORMATION_SCHEMA.QUERY_HISTORY (table function)
-- fallback_note: last 7 days at most, only the queries this role can see
-- Same columns as checks/query_queuing_waits.sql; the warehouse name stands in for its id.
WITH -- The INFORMATION_SCHEMA fallback's query feed, shared by the fallback checks.
-- QUERY_HISTORY (the table function) keeps 7 days, returns at most 10,000 rows a call and shows only
-- the queries this role can see (its own, and those on warehouses it has MONITOR or OPERATE on).
-- So: 28 calls of 6 hours each (up to 280,000 queries), the oldest starting 5 minutes inside the
-- 7-day limit, one row per query id. It has no warehouse id: the name stands in for it.
is_query_history AS (
  SELECT *, warehouse_name AS warehouse_id
  FROM (
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -6, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => CURRENT_TIMESTAMP(), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -12, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -6, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -18, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -12, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -24, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -18, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -30, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -24, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -36, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -30, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -42, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -36, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -48, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -42, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -54, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -48, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -60, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -54, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -66, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -60, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -72, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -66, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -78, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -72, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -84, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -78, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -90, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -84, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -96, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -90, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -102, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -96, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -108, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -102, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -114, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -108, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -120, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -114, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -126, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -120, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -132, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -126, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -138, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -132, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -144, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -138, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -150, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -144, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -156, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -150, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(hour, -162, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -156, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT query_id, query_type, user_name, role_name, warehouse_name, warehouse_size, execution_status, error_code, error_message, start_time, end_time, total_elapsed_time, execution_time, compilation_time, queued_overload_time, queued_provisioning_time, bytes_scanned
    FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => DATEADD(minute, -10075, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END => DATEADD(hour, -162, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
  )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY end_time DESC) = 1
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
