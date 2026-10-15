-- The INFORMATION_SCHEMA fallback's query feed, shared by the fallback checks.
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
)
