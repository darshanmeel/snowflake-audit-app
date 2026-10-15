-- shim: QUERY_HISTORY
-- reads: INFORMATION_SCHEMA.QUERY_HISTORY (table function)
-- note: queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
-- QUERY_HISTORY rebuilt from the shared query feed (common/is_query_history_feed.sql): finished queries
-- only, with the view's status names. The columns the table function lacks are NULL; the warehouse,
-- database and schema names stand in for their ids.
SELECT query_id, query_text, database_name AS database_id, database_name, schema_name AS schema_id, schema_name,
       query_type, session_id, authn_event_id, user_name, role_name, warehouse_id, warehouse_name, warehouse_size,
       warehouse_type, cluster_number, query_tag,
       DECODE(UPPER(execution_status), 'FAILED_WITH_ERROR', 'FAIL', 'FAILED_WITH_INCIDENT', 'INCIDENT',
              UPPER(execution_status)) AS execution_status,
       error_code, error_message, start_time, end_time, total_elapsed_time, bytes_scanned,
       CAST(NULL AS FLOAT) AS percentage_scanned_from_cache, CAST(NULL AS NUMBER) AS bytes_written,
       bytes_written_to_result, CAST(NULL AS NUMBER) AS bytes_read_from_result, rows_produced, rows_inserted,
       CAST(NULL AS NUMBER) AS rows_updated, CAST(NULL AS NUMBER) AS rows_deleted, CAST(NULL AS NUMBER) AS rows_unloaded,
       CAST(NULL AS NUMBER) AS bytes_deleted, CAST(NULL AS NUMBER) AS partitions_scanned,
       CAST(NULL AS NUMBER) AS partitions_total, CAST(NULL AS NUMBER) AS bytes_spilled_to_local_storage,
       CAST(NULL AS NUMBER) AS bytes_spilled_to_remote_storage, CAST(NULL AS NUMBER) AS bytes_sent_over_the_network,
       compilation_time, execution_time, queued_provisioning_time, queued_repair_time, queued_overload_time,
       transaction_blocked_time, outbound_data_transfer_cloud, outbound_data_transfer_region,
       outbound_data_transfer_bytes, inbound_data_transfer_cloud, inbound_data_transfer_region,
       inbound_data_transfer_bytes, list_external_file_time AS list_external_files_time, credits_used_cloud_services,
       release_version, external_function_total_invocations, external_function_total_sent_rows,
       external_function_total_received_rows, external_function_total_sent_bytes,
       external_function_total_received_bytes, CAST(NULL AS NUMBER) AS query_load_percent,
       is_client_generated_statement, query_acceleration_bytes_scanned, query_acceleration_partitions_scanned,
       query_acceleration_upper_limit_scale_factor, transaction_id, CAST(NULL AS NUMBER) AS child_queries_wait_time,
       CAST(NULL AS VARCHAR) AS role_type, query_hash, query_hash_version, query_parameterized_hash,
       query_parameterized_hash_version, CAST(NULL AS VARIANT) AS secondary_role_stats, rows_written_to_result,
       query_retry_time, query_retry_cause, fault_handling_time, user_type, user_database_name,
       CAST(NULL AS NUMBER) AS user_database_id, user_schema_name, CAST(NULL AS NUMBER) AS user_schema_id,
       CAST(NULL AS VARCHAR) AS resource_constraint, CAST(NULL AS VARCHAR) AS generation, agent_type
FROM (__IS_QUERY_HISTORY_SCANS__)
WHERE UPPER(execution_status) IN ('SUCCESS', 'FAIL', 'INCIDENT', 'FAILED_WITH_ERROR', 'FAILED_WITH_INCIDENT')
QUALIFY ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY end_time DESC) = 1
