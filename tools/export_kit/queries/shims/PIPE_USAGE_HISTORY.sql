-- shim: PIPE_USAGE_HISTORY
-- reads: INFORMATION_SCHEMA.PIPE_USAGE_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: pipe credits for the last 14 days only; the pipe name stands in for its id
-- PIPE_USAGE_HISTORY rebuilt from INFORMATION_SCHEMA.PIPE_USAGE_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT pipe_name AS pipe_id,
       CAST(pipe_name AS VARCHAR) AS pipe_name,
       CAST(start_time AS TIMESTAMP_LTZ(9)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       CAST(credits_used AS NUMBER(38,9)) AS credits_used,
       CAST(bytes_inserted AS FLOAT) AS bytes_inserted,
       files_inserted AS files_inserted,
       CAST(bytes_billed AS NUMBER(38,0)) AS bytes_billed
FROM TABLE(__INFO_SCHEMA__.PIPE_USAGE_HISTORY(DATE_RANGE_START => DATEADD(day, -14, CURRENT_DATE()), DATE_RANGE_END => CURRENT_TIMESTAMP()))
