-- query_id: query_failed_queries_daily
-- reads: INFORMATION_SCHEMA.QUERY_HISTORY (table function)
-- fallback_note: last 7 days at most, only the queries this role can see
-- Same columns as checks/query_failed_queries_daily.sql. The table function names failures
-- FAILED_WITH_ERROR / FAILED_WITH_INCIDENT; the warehouse name stands in for its id.
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
f AS (
  SELECT DATE(start_time) AS day,
         IFF(warehouse_name IS NULL, 'CLOUD_SERVICES', 'WAREHOUSE') AS compute_type,
         warehouse_id,
         IFF(TO_VARCHAR(error_code) = '604', 'CANCELED', 'FAILED') AS execution_status,
         query_type AS statement_type, user_name AS executed_by,
         total_elapsed_time, execution_time, error_message, start_time
  FROM is_query_history
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND UPPER(execution_status) IN ('FAIL', 'INCIDENT', 'FAILED_WITH_ERROR', 'FAILED_WITH_INCIDENT')
)
SELECT :period_days AS window_days, day, __ACCOUNT_ID__ AS account_id, compute_type, warehouse_id,
       execution_status, statement_type, executed_by,
       COUNT(*) AS query_count,
       SUM(total_elapsed_time) AS total_duration_ms_sum,
       SUM(execution_time) AS execution_duration_ms_sum,
       -- the latest error, de-valued: emails, then single-quoted literals
       REGEXP_REPLACE(
         REGEXP_REPLACE(MAX_BY(error_message, start_time), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'),
         '''[^'']*''', '?') AS error_message_sample,
       CASE
         WHEN COUNT(*) >= :crit_failed_count THEN 'CRITICAL'
         WHEN COUNT(*) >= :warn_failed_count THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
GROUP BY day, compute_type, warehouse_id, execution_status, statement_type, executed_by
ORDER BY query_count DESC
