-- query_id: sf_pipe_inactive
-- title: Pipes that stopped loading
-- domain: jobs_pipelines   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.PIPES, SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :stale_days (default 7) stale days: value this check uses; :lookback_days (default 90)
--   lookback days: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one pipe that exists (not dropped). last_load_time is the latest hour the pipe
--   inserted files (PIPE_USAGE_HISTORY) or its latest COPY_HISTORY row, within lookback_days. A pipe
--   that loaded before and then stopped usually means a broken event notification, a changed bucket
--   path, a paused pipe or a producer that stopped writing.
-- healthy: status = OK when the pipe loaded within the last stale_days.
-- investigate_if: WARN when a pipe that loaded in the lookback has loaded nothing for stale_days;
--   CRITICAL when that pipe is auto-ingest and its last files failed to load. Pipes with no load at all
--   in lookback_days are WARN (dead objects to drop or fix).
-- actions: 1) run SELECT SYSTEM$PIPE_STATUS('<pipe>') and check executionState and the notification
--   channel (free); 2) ALTER PIPE ... REFRESH to pick up missed files (free); 3) drop pipes nobody uses
--   (free).
-- next: none
-- caveats: a pipe for a source that is only written weekly or monthly will look stale; raise stale_days
--   for it. PIPES lists pipes the view can see; ACCOUNT_USAGE lags up to 3 hours.
WITH p AS (
  SELECT TO_VARCHAR(pipe_id) AS pipe_id, pipe_name, pipe_catalog AS database_name,
         pipe_schema AS schema_name, pipe_catalog || '.' || pipe_schema || '.' || pipe_name AS pipe_full_name,
         is_autoingest_enabled AS auto_ingest, notification_channel_name, pipe_owner AS owner,
         created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPES
  WHERE deleted IS NULL
),
u AS (
  SELECT TO_VARCHAR(pipe_id) AS pipe_id,
         MAX(IFF(files_inserted > 0, end_time, NULL)) AS last_usage_load_time,
         SUM(files_inserted) AS files_in_lookback, SUM(credits_used) AS credits_in_lookback
  -- FILES_INSERTED is a VARIANT, so it is cast before it is summed.
  FROM (SELECT pipe_id, pipe_name, start_time, end_time, credits_used, bytes_inserted,
               TRY_TO_DOUBLE(TO_VARCHAR(files_inserted)) AS files_inserted
        FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY)
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
c AS (
  SELECT pipe_catalog_name || '.' || pipe_schema_name || '.' || pipe_name AS pipe_full_name,
         MAX(last_load_time) AS last_copy_time,
         MAX_BY(status, last_load_time) AS last_copy_status,
         LEFT(REGEXP_REPLACE(REGEXP_REPLACE(MAX_BY(first_error_message, last_load_time), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'), '''[^'']*''', '?'), 500) AS last_copy_error,
         MAX_BY(table_catalog_name || '.' || table_schema_name || '.' || table_name, last_load_time) AS target_table
  FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
  WHERE last_load_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND last_load_time < __AS_OF_DATE__
    AND pipe_name IS NOT NULL
  GROUP BY 1
),
j AS (
  SELECT p.*, c.target_table, c.last_copy_status, c.last_copy_error,
         COALESCE(u.files_in_lookback, 0) AS files_in_lookback, COALESCE(u.credits_in_lookback, 0) AS credits_in_lookback,
         GREATEST_IGNORE_NULLS(u.last_usage_load_time, c.last_copy_time) AS last_load_time,
         DATEDIFF('day', GREATEST_IGNORE_NULLS(u.last_usage_load_time, c.last_copy_time), __AS_OF_DATE__)
           AS days_since_load,
         DATEDIFF('day', p.created, __AS_OF_DATE__) AS days_since_created
  FROM p
  LEFT JOIN u ON u.pipe_id = p.pipe_id
  LEFT JOIN c ON c.pipe_full_name = p.pipe_full_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       pipe_full_name, pipe_name, pipe_id, database_name, schema_name, owner, auto_ingest,
       notification_channel_name, target_table, created, last_altered, last_load_time, days_since_load,
       files_in_lookback, credits_in_lookback, last_copy_status, LEFT(last_copy_error, 500) AS last_copy_error,
       :stale_days AS stale_days,
       CASE WHEN last_load_time IS NULL THEN 'no load in ' || :lookback_days || ' days'
            ELSE 'last load ' || days_since_load || ' days ago' END AS inactive_reason,
       CASE WHEN last_load_time IS NULL AND days_since_created <= :stale_days THEN 'created_recently' END
         AS not_assessed_reason,
       CASE
         WHEN last_load_time IS NULL AND days_since_created <= :stale_days THEN 'NOT_ASSESSED'
         WHEN last_load_time IS NULL THEN 'WARN'
         WHEN days_since_load < :stale_days THEN 'OK'
         WHEN auto_ingest = 'YES' AND UPPER(last_copy_status) LIKE '%FAIL%' THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, days_since_load DESC NULLS FIRST
