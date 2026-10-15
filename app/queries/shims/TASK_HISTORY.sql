-- shim: TASK_HISTORY
-- reads: INFORMATION_SCHEMA.TASK_HISTORY (table function)
-- note: task runs for the last 7 days at most, up to 10,000 a day, only tasks this role owns or can monitor (MONITOR EXECUTION shows all)
-- TASK_HISTORY rebuilt from INFORMATION_SCHEMA.TASK_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(name AS VARCHAR) AS name,
       CAST(query_text AS VARCHAR) AS query_text,
       CAST(condition_text AS VARCHAR) AS condition_text,
       CAST(schema_name AS VARCHAR) AS schema_name,
       database_name || '.' || schema_name AS task_schema_id,
       CAST(database_name AS VARCHAR) AS database_name,
       database_name AS task_database_id,
       CAST(scheduled_time AS TIMESTAMP_LTZ(3)) AS scheduled_time,
       CAST(completed_time AS TIMESTAMP_LTZ(3)) AS completed_time,
       CAST(state AS VARCHAR) AS state,
       CAST(return_value AS VARCHAR) AS return_value,
       CAST(query_id AS VARCHAR) AS query_id,
       CAST(query_start_time AS TIMESTAMP_LTZ(3)) AS query_start_time,
       CAST(error_code AS VARCHAR) AS error_code,
       CAST(error_message AS VARCHAR) AS error_message,
       CAST(graph_version AS NUMBER(38,0)) AS graph_version,
       CAST(run_id AS NUMBER(38,0)) AS run_id,
       CAST(root_task_id AS VARCHAR) AS root_task_id,
       CAST(scheduled_from AS VARCHAR) AS scheduled_from,
       CAST(NULL AS NUMBER(38,0)) AS instance_id,
       CAST(attempt_number AS NUMBER(38,0)) AS attempt_number,
       CAST(config AS VARCHAR) AS config,
       CAST(query_hash AS VARCHAR) AS query_hash,
       CAST(query_hash_version AS NUMBER(38,0)) AS query_hash_version,
       CAST(query_parameterized_hash AS VARCHAR) AS query_parameterized_hash,
       CAST(query_parameterized_hash_version AS NUMBER(38,0)) AS query_parameterized_hash_version,
       CAST(graph_run_group_id AS VARCHAR) AS graph_run_group_id,
       backfill_info AS backfill_info,
       CAST(spcs_job_id AS NUMBER(38,0)) AS spcs_job_id,
       CAST(scheduled_by_user AS VARCHAR) AS scheduled_by_user
FROM (
  SELECT * FROM TABLE(__INFO_SCHEMA__.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day, -1, CURRENT_TIMESTAMP()), SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(), RESULT_LIMIT => 10000))
  UNION ALL
  SELECT * FROM TABLE(__INFO_SCHEMA__.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day, -2, CURRENT_TIMESTAMP()), SCHEDULED_TIME_RANGE_END => DATEADD(day, -1, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
  UNION ALL
  SELECT * FROM TABLE(__INFO_SCHEMA__.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day, -3, CURRENT_TIMESTAMP()), SCHEDULED_TIME_RANGE_END => DATEADD(day, -2, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
  UNION ALL
  SELECT * FROM TABLE(__INFO_SCHEMA__.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day, -4, CURRENT_TIMESTAMP()), SCHEDULED_TIME_RANGE_END => DATEADD(day, -3, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
  UNION ALL
  SELECT * FROM TABLE(__INFO_SCHEMA__.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day, -5, CURRENT_TIMESTAMP()), SCHEDULED_TIME_RANGE_END => DATEADD(day, -4, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
  UNION ALL
  SELECT * FROM TABLE(__INFO_SCHEMA__.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(day, -6, CURRENT_TIMESTAMP()), SCHEDULED_TIME_RANGE_END => DATEADD(day, -5, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
  UNION ALL
  SELECT * FROM TABLE(__INFO_SCHEMA__.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(minute, -10075, CURRENT_TIMESTAMP()), SCHEDULED_TIME_RANGE_END => DATEADD(day, -6, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
)
WHERE state <> 'SCHEDULED'
QUALIFY ROW_NUMBER() OVER (PARTITION BY query_id, name, scheduled_time ORDER BY completed_time DESC NULLS LAST) = 1
