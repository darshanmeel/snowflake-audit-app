-- shim: SERVERLESS_TASK_HISTORY
-- reads: INFORMATION_SCHEMA.SERVERLESS_TASK_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: serverless task credits for 6 months at most; no database or schema names, and the task name stands in for its id
-- SERVERLESS_TASK_HISTORY rebuilt from INFORMATION_SCHEMA.SERVERLESS_TASK_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(start_time AS TIMESTAMP_LTZ(9)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       CAST(credits_used AS NUMBER(38,9)) AS credits_used,
       task_name AS task_id,
       CAST(task_name AS VARCHAR) AS task_name,
       CAST(NULL AS NUMBER(38,0)) AS schema_id,
       CAST(NULL AS VARCHAR) AS schema_name,
       CAST(NULL AS NUMBER(38,0)) AS database_id,
       CAST(NULL AS VARCHAR) AS database_name,
       CAST(NULL AS NUMBER(38,0)) AS instance_id
FROM TABLE(__INFO_SCHEMA__.SERVERLESS_TASK_HISTORY(DATE_RANGE_START => DATEADD(day, 1, DATEADD(month, -6, CURRENT_DATE())), DATE_RANGE_END => CURRENT_TIMESTAMP()))
