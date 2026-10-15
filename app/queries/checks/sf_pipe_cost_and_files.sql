-- query_id: sf_pipe_cost_and_files
-- title: What each Snowpipe costs per GB and per file
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.PIPES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 50) usd: at or above this the row reads WARN; :crit_usd (default 500) usd:
--   at or above this the row reads CRITICAL; :min_avg_file_mb (default 10) avg file mb: least a row
--   needs before it can flag; :min_files (default 1000) files: least a row needs before it can flag;
--   :warn_growth_pct (default 50) growth pct: at or above this the row reads WARN; :min_growth_usd
--   (default 10) growth usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one pipe (database.schema.pipe). credits, files and bytes are what the pipe
--   loaded in the window; avg_file_mb is bytes per file; est_usd_per_gb is what one GB loaded costs.
--   Many tiny files cost more per GB because Snowpipe also bills per file handled.
-- healthy: status = OK when the pipe costs under warn_usd, files average at least min_avg_file_mb and
--   cost did not jump.
-- investigate_if: WARN when est_pipe_usd_list >= warn_usd, avg_file_mb < min_avg_file_mb over at least
--   min_files files, or cost grew >= warn_growth_pct and by >= min_growth_usd; CRITICAL when
--   est_pipe_usd_list >= crit_usd.
-- actions: 1) have the producer write bigger files (100-250 MB compressed) or batch them (free); 2) for
--   a steady row stream use Snowpipe Streaming instead of one file per event (config); 3) for rare
--   large drops use a scheduled COPY on a warehouse already running (config).
-- next: none
-- caveats: PIPE_USAGE_HISTORY lags up to 3 hours and is billed per hour bucket. The Snowpipe price
--   model (per-file overhead or per-GB) depends on account edition and date, so est_usd_per_gb is the
--   observed rate, not the list rate. Pipes dropped in the window show their last name. A row with no
--   pipe id is the internal pipe that auto-refreshes external tables and directory tables.
WITH u AS (
  SELECT TO_VARCHAR(pipe_id) AS pipe_id, MAX(pipe_name) AS pipe_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), files_inserted, 0)) AS files_inserted,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_inserted, 0)) AS bytes_inserted,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS prev_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), files_inserted, 0)) AS prev_files_inserted,
         MAX(IFF(files_inserted > 0, end_time, NULL)) AS last_load_time
  -- FILES_INSERTED is a VARIANT, so it is cast before it is summed.
  FROM (SELECT pipe_id, pipe_name, start_time, end_time, credits_used, bytes_inserted,
               TRY_TO_DOUBLE(TO_VARCHAR(files_inserted)) AS files_inserted
        FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY)
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
p AS (
  SELECT TO_VARCHAR(pipe_id) AS pipe_id,
         MAX_BY(pipe_catalog || '.' || pipe_schema || '.' || pipe_name, created) AS pipe_full_name,
         MAX_BY(pipe_catalog, created) AS database_name, MAX_BY(pipe_schema, created) AS schema_name,
         MAX_BY(is_autoingest_enabled, created) AS auto_ingest,
         MAX_BY(pipe_owner, created) AS owner,
         MAX(deleted) AS deleted
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPES
  GROUP BY 1
),
scored AS (
  SELECT u.*, p.pipe_full_name, p.database_name, p.schema_name, p.auto_ingest, p.owner, p.deleted,
         bytes_inserted / POWER(1024, 3) AS gb_inserted,
         bytes_inserted / POWER(1024, 2) / NULLIF(files_inserted, 0) AS avg_file_mb,
         credits * __CREDIT_PRICE__ AS usd,
         prev_credits * __CREDIT_PRICE__ AS prev_usd
  FROM u LEFT JOIN p ON p.pipe_id = u.pipe_id
  WHERE u.credits > 0 OR u.files_inserted > 0 OR u.prev_credits > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       -- no pipe id or name: Snowflake's internal pipe that auto-refreshes external and directory tables
       COALESCE(pipe_full_name, pipe_name, IFF(pipe_id IS NULL, '(external table auto-refresh)', NULL)) AS pipe_full_name,
       pipe_name, pipe_id, database_name,
       schema_name, owner, auto_ingest, deleted AS dropped_on,
       files_inserted, gb_inserted, avg_file_mb, credits, prev_credits, prev_files_inserted,
       credits / NULLIF(gb_inserted, 0) AS credits_per_gb,
       1000 * credits / NULLIF(files_inserted, 0) AS credits_per_1000_files,
       usd AS est_pipe_usd_list, prev_usd AS est_prev_usd_list,
       usd / NULLIF(gb_inserted, 0) AS est_usd_per_gb,
       100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
       last_load_time,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       files_inserted || ' files, ' || ROUND(gb_inserted, 2) || ' GB (avg ' || ROUND(avg_file_mb, 2)
         || ' MB/file), ' || ROUND(credits, 2) || ' credits' AS pipe_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd
           OR (files_inserted >= :min_files AND avg_file_mb < :min_avg_file_mb)
           OR (usd - prev_usd >= :min_growth_usd
               AND 100 * (credits - prev_credits) / NULLIF(prev_credits, 0) >= :warn_growth_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY est_pipe_usd_list DESC NULLS LAST, credits DESC
