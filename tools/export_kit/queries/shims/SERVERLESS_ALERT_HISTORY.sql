-- shim: SERVERLESS_ALERT_HISTORY
-- reads: INFORMATION_SCHEMA.SERVERLESS_ALERT_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: serverless alert credits for 6 months at most; no database or schema names, and the alert name stands in for its id
-- SERVERLESS_ALERT_HISTORY rebuilt from INFORMATION_SCHEMA.SERVERLESS_ALERT_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(start_time AS TIMESTAMP_LTZ(9)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       CAST(credits_used AS NUMBER(38,9)) AS credits_used,
       alert_name AS alert_id,
       CAST(alert_name AS VARCHAR) AS alert_name,
       CAST(NULL AS NUMBER(38,0)) AS schema_id,
       CAST(NULL AS VARCHAR) AS schema_name,
       CAST(NULL AS NUMBER(38,0)) AS database_id,
       CAST(NULL AS VARCHAR) AS database_name
FROM TABLE(__INFO_SCHEMA__.SERVERLESS_ALERT_HISTORY(DATE_RANGE_START => DATEADD(day, 1, DATEADD(month, -6, CURRENT_DATE())), DATE_RANGE_END => CURRENT_TIMESTAMP()))
