-- query_id: sf_load_snowpipe_latency
-- title: Snowpipe files that take long to land
-- domain: jobs_pipelines   tier: standard
-- entity: pipes = pipe_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.PIPES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_files (default 20) files: least a row needs before it can flag; :warn_p95_seconds
--   (default 300) seconds: a p95 landing time at or above this reads WARN; :crit_p95_seconds (default
--   1800) seconds: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one pipe and target table with at least min_files loaded files. Landing time is
--   from the moment the pipe was told about the file (PIPE_RECEIVED_TIME) to its first commit into the
--   table; p50 is the typical file, p95 the slow tail. is_autoingest tells whether cloud notifications
--   feed the pipe, the usual place a delay starts.
-- healthy: status = OK when 95 in 100 files land in under warn_p95_seconds.
-- investigate_if: WARN when p95_latency_seconds >= warn_p95_seconds; CRITICAL when it is
--   >= crit_p95_seconds.
-- actions: 1) check the stage notifications and the pipe's SYSTEM$PIPE_STATUS for a backlog (free);
--   2) write bigger files less often so each file is not queued behind a burst (free); 3) if a table
--   must be fresh within seconds use Snowpipe Streaming instead (config).
-- next: sf_pipe_cost_and_files
-- empty_if: role_cannot_see, no_activity, ingestion_lag
-- caveats: COPY_HISTORY shows only tables the role can see, and lags up to 2 hours (2 days on tables with
--   little load activity). Only loaded and partially loaded files are counted, so files that never
--   landed are not in the delay. Each file's name and stage path are not stored.
WITH f AS (
  SELECT TO_VARCHAR(table_id) AS table_id,
         table_catalog_name || '.' || table_schema_name || '.' || table_name AS table_full_name,
         pipe_catalog_name || '.' || pipe_schema_name || '.' || pipe_name AS pipe_full_name,
         file_size / POWER(1024, 2) AS file_mb,
         DATEDIFF('second', pipe_received_time, COALESCE(first_commit_time, last_load_time)) AS latency_seconds,
         last_load_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
  WHERE last_load_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND last_load_time < __AS_OF_DATE__
    AND pipe_name IS NOT NULL AND pipe_received_time IS NOT NULL
    AND UPPER(status) IN ('LOADED', 'PARTIALLY LOADED', 'PARTIALLY_LOADED')
),
-- A recreated pipe keeps its name, so only the live pipe of that name is used for the flags.
p AS (
  SELECT pipe_catalog || '.' || pipe_schema || '.' || pipe_name AS pipe_full_name,
         MAX(TO_VARCHAR(pipe_id)) AS pipe_id, MAX(is_autoingest_enabled) AS is_autoingest_enabled
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPES
  WHERE deleted IS NULL
  GROUP BY 1
),
t AS (
  SELECT table_id, pipe_full_name, MAX(table_full_name) AS table_full_name,
         COUNT(*) AS files,
         AVG(file_mb) AS avg_file_mb,
         MEDIAN(GREATEST(latency_seconds, 0)) AS p50_latency_seconds,
         APPROX_PERCENTILE(GREATEST(latency_seconds, 0), 0.95) AS p95_latency_seconds,
         MAX(latency_seconds) AS max_latency_seconds,
         MAX(last_load_time) AS last_load_time
  FROM f
  GROUP BY table_id, pipe_full_name
  HAVING COUNT(*) >= :min_files
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       COALESCE(t.pipe_full_name, 'unknown') || ' (' || COALESCE(p.pipe_id, '?') || ')' AS pipe_display_name,
       t.pipe_full_name, p.pipe_id, table_full_name, t.table_id,
       p.is_autoingest_enabled = 'YES' AS is_autoingest,
       files, ROUND(avg_file_mb, 2) AS avg_file_mb, p50_latency_seconds, p95_latency_seconds,
       max_latency_seconds, last_load_time,
       'p95 file lands in ' || ROUND(p95_latency_seconds) || ' s over ' || files || ' files' AS performance_reason,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN p95_latency_seconds >= :crit_p95_seconds THEN 'CRITICAL'
         WHEN p95_latency_seconds >= :warn_p95_seconds THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t LEFT JOIN p ON p.pipe_full_name = t.pipe_full_name
ORDER BY p95_latency_seconds DESC NULLS LAST
