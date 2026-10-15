-- One six-hour slice of the INFORMATION_SCHEMA fallback's query feed. The export runs 28 slices at
-- once, each its own statement with its own timeout, before the checks; the fallback checks read
-- them all through RESULT_SCAN (common/is_query_history.sql), so the slow table function is called
-- once per export, and a slow slice drops only its own six hours.
-- QUERY_HISTORY (the table function) keeps 7 days, returns at most 10,000 rows a call and shows only
-- the queries this role can see (its own, and those on warehouses it has MONITOR or OPERATE on).
-- Error text is kept for failed queries only. It has no warehouse id: the name stands in for it.
SELECT query_id, query_type, user_name, warehouse_name, warehouse_name AS warehouse_id, warehouse_size,
       execution_status, error_code,
       IFF(UPPER(execution_status) IN ('FAIL', 'INCIDENT', 'FAILED_WITH_ERROR', 'FAILED_WITH_INCIDENT'), error_message, NULL) AS error_message,
       start_time, end_time, total_elapsed_time, execution_time, queued_overload_time, queued_provisioning_time, bytes_scanned
FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => __SLICE_START__,
     END_TIME_RANGE_END => __SLICE_END__, RESULT_LIMIT => 10000))
