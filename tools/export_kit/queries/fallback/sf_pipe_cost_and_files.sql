-- query_id: sf_pipe_cost_and_files
-- shims: PIPE_USAGE_HISTORY, PIPES
-- reads: INFORMATION_SCHEMA table functions PIPE_USAGE_HISTORY, PIPES (view, per database)
-- fallback_note: pipe credits for the last 14 days only; the pipe name stands in for its id; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- needs: MONITOR USAGE
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
        FROM __SHIM_PIPE_USAGE_HISTORY__)
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
  FROM __SHIM_PIPES__
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
