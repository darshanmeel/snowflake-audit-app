-- query_id: sf_pipe_invalid_or_unnotified
-- title: Pipes that are broken, or fail with nobody told
-- domain: jobs_pipelines   tier: standard
-- entity: pipes = pipe_full_name
-- windowed: yes
-- pre: SHOW PIPES IN ACCOUNT
-- reads: SHOW PIPES IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.PIPES, SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR EXECUTION on the account, or
--   OWNERSHIP, MONITOR or OPERATE on each pipe (SHOW PIPES lists only pipes the role has a privilege on)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :crit_failed_files (default 100) failed files in the window at or above which a pipe with no
--   error integration reads CRITICAL
-- empty_if: role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- not_assessed_reasons: pipes_not_visible: ACCOUNT_USAGE.PIPES lists live pipes that SHOW PIPES does not
--   (the role has no privilege on them), so their state is not known
-- read_this: one row = one pipe SHOW PIPES lists. invalid_reason is Snowflake's own note on a pipe that
--   has a problem (a dropped or changed stage, a lost grant). auto_ingest is true when the pipe loads on
--   cloud events (a notification channel or integration). error_integration is the notification
--   integration that sends its load errors; empty means nobody is told when a file fails.
--   failed_files counts files with status Load failed in the window (COPY_HISTORY). finding: invalid,
--   failing_unnotified, no_error_alerts (auto-ingest with no error integration), rest_api (loads through
--   the REST API; error alerts are not judged) or ok.
-- healthy: status = OK when the pipe is valid and, if it loads on cloud events, sends its errors
--   somewhere.
-- investigate_if: WARN when an auto-ingest pipe has no error integration, or files failed and none is
--   set; CRITICAL when the pipe is invalid, or crit_failed_files or more failed with no error integration.
-- actions: 1) for an invalid pipe, fix what invalid_reason names (recreate the stage, restore the
--   grant) and run ALTER PIPE ... REFRESH for the files it missed (free); 2) create a notification
--   integration for errors and ALTER PIPE ... SET ERROR_INTEGRATION = <name> (free); 3) review
--   failed files in sf_load_copy_errors (free)
-- next: sf_pipe_inactive, sf_load_copy_errors
-- caveats: SHOW PIPES is current at the export and lists only pipes the role has a privilege on.
--   Whether a pipe is paused is only in SYSTEM$PIPE_STATUS, which this check does not call; a paused
--   pipe that stops loading shows in sf_pipe_inactive. COPY_HISTORY lags up to 2 hours and lists only
--   tables the role can see.
WITH sp AS (
  SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS pipe_full_name, "name" AS pipe_name,
         "database_name" AS database_name, "schema_name" AS schema_name, "owner" AS pipe_owner,
         NULLIF(TRIM(TO_VARCHAR("notification_channel")), '') AS notification_channel,
         NULLIF(TRIM(TO_VARCHAR("integration")), '') AS integration,
         NULLIF(NULLIF(TRIM(TO_VARCHAR("error_integration")), ''), 'null') AS error_integration,
         NULLIF(NULLIF(TRIM(TO_VARCHAR("invalid_reason")), ''), 'null') AS invalid_reason,
         CAST("created_on" AS TIMESTAMP_LTZ) AS created_on
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
),
ap AS (
  -- live pipes, the latest row of each, for the id and the auto-ingest flag
  SELECT pipe_catalog || '.' || pipe_schema || '.' || pipe_name AS pipe_full_name, pipe_id,
         UPPER(TO_VARCHAR(is_autoingest_enabled)) IN ('YES', 'TRUE', 'Y') AS au_autoingest
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPES
  WHERE deleted IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY pipe_catalog, pipe_schema, pipe_name ORDER BY last_altered DESC NULLS LAST) = 1
),
ch AS (
  SELECT pipe_catalog_name || '.' || pipe_schema_name || '.' || pipe_name AS pipe_full_name,
         COUNT(*) AS files, COUNT_IF(status = 'Load failed') AS failed_files,
         COUNT_IF(status = 'Partially loaded') AS partial_files,
         MAX(IFF(status = 'Load failed', last_load_time, NULL)) AS last_failed_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
  WHERE last_load_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND last_load_time < __AS_OF_DATE__
    AND pipe_name IS NOT NULL
  GROUP BY 1
),
s AS (
  SELECT sp.*, TO_VARCHAR(ap.pipe_id) AS pipe_id,
         COALESCE(sp.notification_channel IS NOT NULL OR sp.integration IS NOT NULL, FALSE) OR COALESCE(ap.au_autoingest, FALSE) AS auto_ingest,
         COALESCE(ch.files, 0) AS files, COALESCE(ch.failed_files, 0) AS failed_files,
         COALESCE(ch.partial_files, 0) AS partial_files, ch.last_failed_time
  FROM sp
  LEFT JOIN ap ON ap.pipe_full_name = sp.pipe_full_name
  LEFT JOIN ch ON ch.pipe_full_name = sp.pipe_full_name
),
f AS (
  SELECT s.*,
         CASE WHEN invalid_reason IS NOT NULL THEN 'invalid'
              WHEN error_integration IS NULL AND failed_files > 0 THEN 'failing_unnotified'
              WHEN error_integration IS NULL AND auto_ingest THEN 'no_error_alerts'
              WHEN NOT auto_ingest THEN 'rest_api'
              ELSE 'ok' END AS finding
  FROM s
),
main AS (
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, pipe_full_name, pipe_name, pipe_id, database_name,
         schema_name, pipe_owner, created_on, auto_ingest, error_integration, LEFT(invalid_reason, 300) AS invalid_reason,
         files, failed_files, partial_files, last_failed_time, finding,
         CAST(NULL AS VARCHAR) AS not_assessed_reason,
         CASE WHEN finding = 'invalid' THEN 'CRITICAL'
              WHEN finding = 'failing_unnotified' AND failed_files >= :crit_failed_files THEN 'CRITICAL'
              WHEN finding IN ('failing_unnotified', 'no_error_alerts') THEN 'WARN'
              ELSE 'OK' END AS status
  FROM f
),
blind AS (
  -- live pipes the role cannot list with SHOW: their state is unknown, never clean
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
         CAST('(' || COUNT(*) || ' pipes in ACCOUNT_USAGE.PIPES not listed by SHOW PIPES)' AS VARCHAR) AS pipe_full_name,
         CAST(NULL AS VARCHAR) AS pipe_name, CAST(NULL AS VARCHAR) AS pipe_id, CAST(NULL AS VARCHAR) AS database_name,
         CAST(NULL AS VARCHAR) AS schema_name, CAST(NULL AS VARCHAR) AS pipe_owner, CAST(NULL AS TIMESTAMP_LTZ) AS created_on,
         CAST(NULL AS BOOLEAN) AS auto_ingest, CAST(NULL AS VARCHAR) AS error_integration, CAST(NULL AS VARCHAR) AS invalid_reason,
         CAST(NULL AS NUMBER) AS files, CAST(NULL AS NUMBER) AS failed_files, CAST(NULL AS NUMBER) AS partial_files,
         CAST(NULL AS TIMESTAMP_LTZ) AS last_failed_time, CAST(NULL AS VARCHAR) AS finding,
         'pipes_not_visible' AS not_assessed_reason, 'NOT_ASSESSED' AS status
  FROM ap
  WHERE ap.pipe_full_name NOT IN (SELECT pipe_full_name FROM sp)
  HAVING COUNT(*) > 0
)
SELECT * FROM (
  SELECT * FROM main
  UNION ALL
  SELECT * FROM blind
)
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END,
         failed_files DESC NULLS LAST, pipe_full_name
