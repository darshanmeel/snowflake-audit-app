-- shim: DYNAMIC_TABLE_REFRESH_HISTORY
-- reads: INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY (table function)
-- note: refreshes for the last 7 days, the latest 10,000 at most, only dynamic tables this role can monitor
-- DYNAMIC_TABLE_REFRESH_HISTORY rebuilt from INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(name AS VARCHAR) AS name,
       CAST(schema_name AS VARCHAR) AS schema_name,
       CAST(database_name AS VARCHAR) AS database_name,
       database_name || '.' || schema_name || '.' || name AS id,
       database_name || '.' || schema_name AS schema_id,
       database_name AS database_id,
       CAST(state AS VARCHAR) AS state,
       CAST(state_code AS VARCHAR) AS state_code,
       CAST(state_message AS VARCHAR) AS state_message,
       CAST(query_id AS VARCHAR) AS query_id,
       CAST(data_timestamp AS TIMESTAMP_LTZ(3)) AS data_timestamp,
       CAST(refresh_start_time AS TIMESTAMP_LTZ(3)) AS refresh_start_time,
       CAST(refresh_end_time AS TIMESTAMP_LTZ(3)) AS refresh_end_time,
       CAST(completion_target AS TIMESTAMP_LTZ(3)) AS completion_target,
       CAST(qualified_name AS VARCHAR) AS qualified_name,
       last_completed_dependency AS last_completed_dependency,
       statistics AS statistics,
       CAST(refresh_action AS VARCHAR) AS refresh_action,
       CAST(refresh_trigger AS VARCHAR) AS refresh_trigger,
       CAST(target_lag_sec AS NUMBER(38,0)) AS target_lag_sec,
       CAST(graph_history_valid_from AS TIMESTAMP_LTZ(3)) AS graph_history_valid_from,
       CAST(warehouse AS VARCHAR) AS warehouse,
       CAST(execute_as_user AS VARCHAR) AS execute_as_user,
       CAST(secondary_role_names AS VARCHAR) AS secondary_role_names
FROM TABLE(__INFO_SCHEMA__.DYNAMIC_TABLE_REFRESH_HISTORY(DATA_TIMESTAMP_START => DATEADD(minute, -10075, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
