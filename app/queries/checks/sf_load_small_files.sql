-- query_id: sf_load_small_files
-- title: Loads made of too many small files
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_mb (default 10) mb: least a row needs before it can flag; :crit_mb (default 1) mb: at or
--   above this the row reads CRITICAL; :min_files (default 1000) files: least a row needs before it can
--   flag; :crit_min_files (default 10000) min files: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one target table and loader (a pipe, or bulk COPY when pipe_full_name is empty)
--   with at least min_files loaded files. avg_file_mb and p50_file_mb are the file sizes as stored on
--   the stage; small_file_pct is the share of files under min_mb. Each file carries a fixed cost
--   (listing, open, commit metadata and, for Snowpipe, a per-file charge), so thousands of tiny files
--   cost more per GB and create many small micro-partitions.
-- healthy: status = OK when files average at least min_mb (Snowflake recommends 100-250 MB compressed).
-- investigate_if: WARN when avg_file_mb < min_mb over at least min_files files; CRITICAL when
--   avg_file_mb < crit_mb over at least crit_min_files files.
-- actions: 1) have the producer buffer and write bigger files, e.g. flush every minute instead of per
--   event (free); 2) for a continuous row stream use Snowpipe Streaming (config); 3) if the target has
--   many small partitions, check automatic clustering cost (see storage checks).
-- next: none
-- caveats: file_size is the staged (usually compressed) size. Only loaded and partially loaded files
--   are counted. COPY_HISTORY lags up to 2 hours. The per-file cost itself is in sf_pipe_cost_and_files
--   for pipes; bulk COPY pays it as warehouse time.
WITH f AS (
  SELECT TO_VARCHAR(table_id) AS table_id,
         table_catalog_name || '.' || table_schema_name || '.' || table_name AS table_full_name,
         table_name, table_catalog_name AS database_name, table_schema_name AS schema_name,
         IFF(pipe_name IS NULL, NULL, pipe_catalog_name || '.' || pipe_schema_name || '.' || pipe_name) AS pipe_full_name,
         file_size / POWER(1024, 2) AS file_mb, row_count, stage_location, last_load_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
  WHERE last_load_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND last_load_time < __AS_OF_DATE__
    AND UPPER(status) IN ('LOADED', 'PARTIALLY LOADED', 'PARTIALLY_LOADED')
),
t AS (
  SELECT table_id, MAX(table_full_name) AS table_full_name, MAX(table_name) AS table_name,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, pipe_full_name,
         COUNT(*) AS files,
         COUNT(*) / :period_days AS files_per_day,
         SUM(file_mb) / 1024 AS total_gb,
         AVG(file_mb) AS avg_file_mb,
         MEDIAN(file_mb) AS p50_file_mb,
         100 * COUNT_IF(file_mb < :min_mb) / COUNT(*) AS small_file_pct,
         AVG(row_count) AS avg_rows_per_file,
         MAX(stage_location) AS sample_stage_location,
         MAX(last_load_time) AS last_load_time
  FROM f
  GROUP BY table_id, pipe_full_name
  HAVING COUNT(*) >= :min_files
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_full_name, table_name, table_id, database_name, schema_name, pipe_full_name,
       IFF(pipe_full_name IS NULL, 'bulk_copy', 'snowpipe') AS load_kind,
       files, files_per_day, total_gb, avg_file_mb, p50_file_mb, small_file_pct, avg_rows_per_file,
       sample_stage_location, last_load_time,
       -- How many files the same data would be at the recommended ~100 MB per file.
       CEIL(total_gb * 1024 / 100) AS files_at_100mb,
       files || ' files averaging ' || ROUND(avg_file_mb, 2) || ' MB (' || ROUND(small_file_pct)
         || '% under ' || :min_mb || ' MB)' AS small_file_reason,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN avg_file_mb < :crit_mb AND files >= :crit_min_files THEN 'CRITICAL'
         WHEN avg_file_mb < :min_mb THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, files DESC
