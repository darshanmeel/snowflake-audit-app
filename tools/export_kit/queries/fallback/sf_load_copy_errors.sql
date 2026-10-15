-- query_id: sf_load_copy_errors
-- shims: COPY_HISTORY
-- reads: INFORMATION_SCHEMA table functions LOAD_HISTORY (view, per database)
-- fallback_note: bulk COPY loads for the last 14 days only, no Snowpipe loads, no file sizes or stage paths, up to 10,000 files a database; only tables this role can see
WITH f AS (
  SELECT TO_VARCHAR(table_id) AS table_id,
         table_catalog_name || '.' || table_schema_name || '.' || table_name AS table_full_name,
         table_name, table_catalog_name AS database_name, table_schema_name AS schema_name,
         IFF(pipe_name IS NULL, NULL, pipe_catalog_name || '.' || pipe_schema_name || '.' || pipe_name) AS pipe_full_name,
         UPPER(REPLACE(status, '_', ' ')) AS load_status,
         file_name, stage_location, last_load_time, row_count, error_count, file_size,
         first_error_message, first_error_line_number, first_error_column_name
  FROM __SHIM_COPY_HISTORY__
  WHERE last_load_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND last_load_time < __AS_OF_DATE__
),
t AS (
  SELECT table_id, MAX(table_full_name) AS table_full_name, MAX(table_name) AS table_name,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, pipe_full_name,
         COUNT(*) AS files,
         COUNT_IF(load_status = 'LOADED') AS loaded_files,
         COUNT_IF(load_status LIKE '%FAIL%') AS failed_files,
         COUNT_IF(load_status LIKE '%PARTIAL%') AS partial_files,
         COUNT_IF(load_status LIKE '%SKIP%') AS skipped_files,
         SUM(COALESCE(row_count, 0)) AS rows_loaded,
         SUM(COALESCE(error_count, 0)) AS error_rows,
         SUM(IFF(load_status LIKE '%FAIL%', file_size, 0)) / POWER(1024, 2) AS failed_mb,
         MAX(IFF(load_status LIKE '%FAIL%' OR load_status LIKE '%PARTIAL%', last_load_time, NULL)) AS last_error_time,
         MAX_BY(file_name, IFF(first_error_message IS NOT NULL, last_load_time, NULL)) AS last_error_file,
         MAX_BY(stage_location, IFF(first_error_message IS NOT NULL, last_load_time, NULL)) AS last_error_stage_location,
         MAX_BY(first_error_message, IFF(first_error_message IS NOT NULL, last_load_time, NULL)) AS last_error_message,
         MAX_BY(first_error_line_number, IFF(first_error_message IS NOT NULL, last_load_time, NULL)) AS last_error_line,
         MAX_BY(first_error_column_name, IFF(first_error_message IS NOT NULL, last_load_time, NULL)) AS last_error_column,
         COUNT(DISTINCT IFF(first_error_message IS NOT NULL, LEFT(first_error_message, 80), NULL)) AS distinct_errors
  FROM f
  GROUP BY table_id, pipe_full_name
  HAVING COUNT_IF(load_status LIKE '%FAIL%' OR load_status LIKE '%PARTIAL%') > 0 OR SUM(COALESCE(error_count, 0)) > 0
),
scored AS (
  SELECT t.*, 100 * failed_files / NULLIF(files, 0) AS failed_pct,
         100 * (failed_files + partial_files) / NULLIF(files, 0) AS failed_or_partial_pct
  FROM t
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_full_name, table_name, table_id, database_name, schema_name, pipe_full_name,
       IFF(pipe_full_name IS NULL, 'bulk_copy', 'snowpipe') AS load_kind,
       files, loaded_files, failed_files, partial_files, skipped_files, failed_pct, failed_or_partial_pct,
       rows_loaded, error_rows, failed_mb, distinct_errors, last_error_time, last_error_file,
       last_error_stage_location, LEFT(REGEXP_REPLACE(REGEXP_REPLACE(last_error_message, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'), '''[^'']*''', '?'), 500) AS last_error_message, last_error_line,
       last_error_column,
       failed_files || ' failed and ' || partial_files || ' partially loaded of ' || files || ' files; '
         || error_rows || ' rows rejected' AS error_reason,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN failed_pct >= :crit_failed_pct OR failed_files >= :crit_failed_files THEN 'CRITICAL'
         WHEN failed_files + partial_files >= :warn_failed_files THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, failed_files DESC, error_rows DESC
