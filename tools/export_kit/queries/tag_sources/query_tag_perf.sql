-- windowed: yes
-- Statement counts, time, queueing and spill per warehouse and query tag (QUERY_HISTORY); a NULL
-- query_tag row is every untagged statement, and a NULL warehouse_id is a statement that used no warehouse.
SELECT :period_days AS window_days, TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
       NULLIF(TRIM(query_tag), '') AS query_tag,
       COUNT(*) AS statements,
       COUNT_IF(execution_status = 'FAIL') AS failed_statements,
       SUM(COALESCE(total_elapsed_time, 0)) AS duration_ms,
       SUM(COALESCE(queued_overload_time, 0) + COALESCE(queued_provisioning_time, 0)) AS queue_ms,
       SUM(COALESCE(bytes_spilled_to_local_storage, 0) + COALESCE(bytes_spilled_to_remote_storage, 0)) AS spill_bytes
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
GROUP BY TO_VARCHAR(warehouse_id), NULLIF(TRIM(query_tag), '')
