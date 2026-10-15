-- query_id: query_workload_mix_hours
-- shims: QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions QUERY_HISTORY
-- fallback_note: queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
SELECT :period_days AS window_days, DATE(start_time) AS day, __ACCOUNT_ID__ AS account_id,
       HOUR(start_time) AS hour_of_day,
       IFF(warehouse_id IS NULL, 'CLOUD_SERVICES', 'WAREHOUSE') AS compute_type,
       -- the same kinds as sf_use_query_type_mix
       CASE
         WHEN query_type = 'SELECT' THEN 'read'
         WHEN query_type IN ('SHOW', 'DESCRIBE', 'DESCRIBE_QUERY', 'USE', 'SET', 'UNSET', 'ALTER_SESSION',
                             'LIST_FILES', 'EXPLAIN', 'COMMIT', 'ROLLBACK', 'BEGIN_TRANSACTION')
           OR query_type LIKE 'SHOW%' OR query_type LIKE 'DESC%' THEN 'metadata'
         WHEN query_type IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE', 'MULTI_TABLE_INSERT', 'COPY', 'UNLOAD',
                             'CREATE_TABLE_AS_SELECT', 'TRUNCATE_TABLE', 'PUT_FILES', 'GET_FILES',
                             'REMOVE_FILES') THEN 'dml'
         WHEN query_type LIKE 'CREATE%' OR query_type LIKE 'ALTER%' OR query_type LIKE 'DROP%'
           OR query_type LIKE 'UNDROP%' OR query_type LIKE 'RENAME%' OR query_type IN ('GRANT', 'REVOKE')
           THEN 'ddl'
         WHEN query_type IN ('CALL', 'EXECUTE_STREAMLIT', 'EXECUTE_TASK') OR query_type LIKE 'EXECUTE%'
           THEN 'procedural'
         ELSE 'other'
       END AS statement_kind,
       COUNT(*) AS query_count,
       COUNT(DISTINCT warehouse_id) AS distinct_warehouses,
       COUNT(DISTINCT user_name) AS distinct_users,
       COUNT_IF(execution_status = 'SUCCESS') AS finished_count,
       SUM(total_elapsed_time) AS total_duration_ms_sum,
       SUM(execution_time) AS execution_duration_ms_sum,
       SUM(bytes_scanned) AS read_bytes_sum,
       SUM(rows_produced) AS produced_rows_sum
FROM __SHIM_QUERY_HISTORY__
WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
-- day x hour x compute x kind: at most 90 x 24 x 2 x 6 rows, under the export's row cap on any account
GROUP BY 2, 4, 5, 6
ORDER BY day DESC, hour_of_day, compute_type, statement_kind
