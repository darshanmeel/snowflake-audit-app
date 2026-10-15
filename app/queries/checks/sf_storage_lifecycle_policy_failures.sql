-- query_id: sf_storage_lifecycle_policy_failures
-- title: Storage lifecycle policies that fail or stopped running (data kept past expiry, or not archived)
-- domain: storage   tier: standard
-- entity: policy attachments = policy_full_name, table_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.STORAGE_LIFECYCLE_POLICY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_LIFECYCLE_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :stale_days (default 3) days since the last run: at or above this a policy that runs daily
--   reads WARN; :crit_failures (default 3) failed runs in a row: at or above this the row reads CRITICAL;
--   :min_policy_age_days (default 7) days a policy must exist before "no runs" can flag
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one storage lifecycle policy on one table. Snowflake runs each policy once a day:
--   EXPIRE deletes the rows its expression matches, ARCHIVE moves them to COOL or COLD storage, and
--   EXPIRE_ARCHIVE deletes archived rows. A failed run leaves those rows where they were: kept past the
--   retention the policy enforces, or billed at the active rate. failed_tasks names the parts that failed;
--   top_error_code is Snowflake's error code (the message is not stored). failures_in_a_row counts the
--   failed runs since the last success. rows_expired and rows_archived are what the successful runs did
--   in the window. finding: failing, not_running (no run for stale_days), no_runs (attached, no run in the
--   window), recovered (failed in the window, ran clean since) or ok.
-- healthy: status = OK when the latest daily run succeeded and is recent.
-- investigate_if: WARN when the latest run failed, the policy stopped running, or an attached policy never
--   ran in the window; CRITICAL at crit_failures failed runs in a row.
-- actions: 1) read the error of the latest run with the STORAGE_LIFECYCLE_POLICY_HISTORY table function
--   and fix its cause (a dropped column in the expression, a lost privilege) (free); 2) check that rows past
--   their expiry are gone after the next run, and tell the data owner if retention was breached (free);
--   3) for archive policies, compare active bytes before and after (see sf_storage_growth_by_database)
--   (free)
-- next: sf_storage_archive_retrieval, sf_storage_retention_policy
-- caveats: only completed runs are listed (no queued, running or cancelled ones). POLICY_REFERENCES lists
--   attachments the role can see, so an attachment it cannot see shows only if it ran. Policy bodies and
--   error messages are never read into the export. The history keeps 12 months and lags up to 2 hours.
WITH h AS (
  SELECT policy_db || '.' || policy_schema || '.' || policy_name AS policy_full_name,
         ref_entity_db || '.' || ref_entity_schema || '.' || ref_entity_name AS table_full_name,
         ref_entity_domain, state, start_time, end_time, execution_result AS er
  FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_LIFECYCLE_POLICY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
-- each run's task parts: the field names are lower case in the docs' example; read both cases
t AS (
  SELECT h.*,
         COALESCE(er:EXPIRE:state, er:EXPIRE:STATE)::VARCHAR AS expire_state,
         COALESCE(er:ARCHIVE:state, er:ARCHIVE:STATE)::VARCHAR AS archive_state,
         COALESCE(er:EXPIRE_ARCHIVE:state, er:EXPIRE_ARCHIVE:STATE)::VARCHAR AS expire_archive_state,
         TRY_TO_NUMBER(COALESCE(er:EXPIRE:rows_expired, er:EXPIRE:ROWS_EXPIRED)::VARCHAR) AS rows_expired,
         TRY_TO_NUMBER(COALESCE(er:ARCHIVE:rows_archived, er:ARCHIVE:ROWS_ARCHIVED)::VARCHAR) AS rows_archived,
         COALESCE(er:EXPIRE:error_message_code, er:EXPIRE:ERROR_MESSAGE_CODE,
                  er:ARCHIVE:error_message_code, er:ARCHIVE:ERROR_MESSAGE_CODE,
                  er:EXPIRE_ARCHIVE:error_message_code, er:EXPIRE_ARCHIVE:ERROR_MESSAGE_CODE)::VARCHAR AS error_code
  FROM h
),
last_ok AS (
  SELECT policy_full_name, table_full_name, MAX(start_time) AS last_success_time
  FROM t WHERE state = 'SUCCEEDED'
  GROUP BY policy_full_name, table_full_name
),
r AS (
  SELECT t.policy_full_name, t.table_full_name, MAX(t.ref_entity_domain) AS object_kind,
         COUNT(*) AS runs, COUNT_IF(t.state = 'FAILED') AS failed_runs,
         MAX(t.start_time) AS last_run_time, MAX_BY(t.state, t.start_time) AS last_state,
         MAX(l.last_success_time) AS last_success_time,
         COUNT_IF(t.state = 'FAILED' AND t.start_time > COALESCE(l.last_success_time, '1970-01-01'::TIMESTAMP_LTZ)) AS failures_in_a_row,
         ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
           IFF(COUNT_IF(t.expire_state = 'FAILED') > 0, 'EXPIRE', NULL),
           IFF(COUNT_IF(t.archive_state = 'FAILED') > 0, 'ARCHIVE', NULL),
           IFF(COUNT_IF(t.expire_archive_state = 'FAILED') > 0, 'EXPIRE_ARCHIVE', NULL))), ', ') AS failed_tasks,
         MODE(IFF(t.state = 'FAILED', t.error_code, NULL)) AS top_error_code,
         SUM(IFF(t.state = 'SUCCEEDED', t.rows_expired, 0)) AS rows_expired,
         SUM(IFF(t.state = 'SUCCEEDED', t.rows_archived, 0)) AS rows_archived
  FROM t
  LEFT JOIN last_ok l ON l.policy_full_name = t.policy_full_name AND l.table_full_name = t.table_full_name
  GROUP BY t.policy_full_name, t.table_full_name
),
pol AS (
  -- DATABASE and SCHEMA are reserved words: quoted
  SELECT "DATABASE" || '.' || "SCHEMA" || '.' || name AS policy_full_name, id AS policy_id, created_on,
         options:ARCHIVE_TIER::VARCHAR AS archive_tier, TRY_TO_NUMBER(options:ARCHIVE_FOR_DAYS::VARCHAR) AS archive_for_days
  FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_LIFECYCLE_POLICIES
  WHERE deleted_on IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY last_altered_on DESC NULLS LAST) = 1
),
att AS (
  SELECT DISTINCT policy_db || '.' || policy_schema || '.' || policy_name AS policy_full_name,
         ref_database_name || '.' || ref_schema_name || '.' || ref_entity_name AS table_full_name,
         ref_entity_domain AS object_kind
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  WHERE policy_kind ILIKE '%LIFECYCLE%'
),
k AS (
  SELECT policy_full_name, table_full_name, MAX(object_kind) AS object_kind
  FROM (SELECT policy_full_name, table_full_name, object_kind FROM r
        UNION ALL
        SELECT policy_full_name, table_full_name, object_kind FROM att)
  GROUP BY policy_full_name, table_full_name
),
j AS (
  SELECT k.policy_full_name, k.table_full_name, k.object_kind, p.policy_id, p.archive_tier, p.archive_for_days,
         p.created_on AS policy_created_on,
         COALESCE(r.runs, 0) AS runs, COALESCE(r.failed_runs, 0) AS failed_runs, r.last_run_time, r.last_state,
         r.last_success_time, COALESCE(r.failures_in_a_row, 0) AS failures_in_a_row,
         NULLIF(r.failed_tasks, '') AS failed_tasks, r.top_error_code, r.rows_expired, r.rows_archived,
         DATEDIFF(day, r.last_run_time, __AS_OF_DATE__) AS days_since_last_run
  FROM k
  LEFT JOIN r ON r.policy_full_name = k.policy_full_name AND r.table_full_name = k.table_full_name
  LEFT JOIN pol p ON p.policy_full_name = k.policy_full_name
),
f AS (
  SELECT j.*,
         CASE WHEN runs = 0 AND COALESCE(DATEDIFF(day, policy_created_on, __AS_OF_DATE__), 9999) >= :min_policy_age_days THEN 'no_runs'
              WHEN runs = 0 THEN 'ok'
              WHEN last_state = 'FAILED' THEN 'failing'
              WHEN days_since_last_run >= :stale_days THEN 'not_running'
              WHEN failed_runs > 0 THEN 'recovered'
              ELSE 'ok' END AS finding
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       policy_full_name || COALESCE(' (' || policy_id || ')', '') AS policy_full_name, table_full_name, object_kind,
       archive_tier, archive_for_days, runs, failed_runs, failures_in_a_row, last_run_time, last_state,
       last_success_time, days_since_last_run, failed_tasks, top_error_code, rows_expired, rows_archived, finding,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN finding = 'failing' AND failures_in_a_row >= :crit_failures THEN 'CRITICAL'
         WHEN finding IN ('failing', 'not_running', 'no_runs') THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY CASE finding WHEN 'failing' THEN 0 WHEN 'not_running' THEN 1 WHEN 'no_runs' THEN 2 WHEN 'recovered' THEN 3 ELSE 4 END,
         failures_in_a_row DESC, policy_full_name
