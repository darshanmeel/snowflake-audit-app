-- query_id: query_provenance_by_source
-- title: Query volume and duration by source (task, BI tool, notebook, ad-hoc)
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account + compute + user + source_kind (job = a task's own statement,
--   notebook, sql_editor = Snowsight, connector = a driver or tool, or other) describing where
--   queries came from. The columns that matter are source_kind (which surface issued the query) and
--   query_count. p95_total_duration_ms is this row's p95; source_p95_total_duration_ms is the p95 over
--   every query of that source_kind, repeated on its rows (percentiles do not add up across rows). An account dominated by "other" or split evenly between ad-hoc (sql_editor,
--   notebook) and scheduled (job) sources tells you whether spend is coming from production
--   pipelines or exploratory work.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: source_kind = job (a task's own statement; job_id = database.schema.task), notebook,
--   sql_editor (Snowsight), connector (JDBC/ODBC/Python/... drivers) or other, from the session's
--   client application. No dashboard or notebook ids; identity_type comes from USERS.type (SERVICE
--   is a service user).
WITH q AS (
  SELECT query_id, session_id, TO_VARCHAR(warehouse_id) AS warehouse_id, user_name,
         execution_time, total_elapsed_time, bytes_scanned
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
tasks AS (
  SELECT query_id, database_name || '.' || schema_name || '.' || name AS job_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND query_id IS NOT NULL
),
users AS (
  SELECT name, type
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY deleted_on DESC NULLS FIRST, created_on DESC) = 1
),
tagged AS (
  SELECT q.*, t.job_id,
         CASE
           WHEN q.user_name IS NULL THEN 'unknown'
           WHEN UPPER(u.type) IN ('SERVICE', 'LEGACY_SERVICE') OR q.user_name = 'SYSTEM' THEN 'service_principal'
           ELSE 'user'
         END AS identity_type,
         CASE
           WHEN t.job_id IS NOT NULL THEN 'job'
           WHEN s.client_application_id ILIKE '%notebook%' THEN 'notebook'
           WHEN s.client_application_id ILIKE 'Snowflake UI%' OR s.client_application_id ILIKE 'Snowflake Web App%'
             THEN 'sql_editor'
           WHEN s.client_application_id IS NOT NULL THEN 'connector'
           ELSE 'other'
         END AS source_kind
  FROM q
  LEFT JOIN tasks t ON t.query_id = q.query_id
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.SESSIONS s ON s.session_id = q.session_id
  LEFT JOIN users u ON u.name = q.user_name
),
-- p95 cannot be combined across rows, so the source-wide figure is computed once and repeated.
src AS (
  SELECT source_kind, APPROX_PERCENTILE(total_elapsed_time, 0.95) AS source_p95_total_duration_ms
  FROM tagged
  GROUP BY source_kind
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       IFF(warehouse_id IS NULL, 'CLOUD_SERVICES', 'WAREHOUSE') AS compute_type, warehouse_id,
       identity_type, user_name AS executed_by, source_kind, job_id,
       CAST(NULL AS VARCHAR) AS dashboard_id, CAST(NULL AS VARCHAR) AS notebook_id,
       COUNT(*) AS query_count,
       SUM(execution_time) AS execution_duration_ms_sum,
       SUM(total_elapsed_time) AS total_duration_ms_sum,
       SUM(bytes_scanned) AS read_bytes_sum,
       APPROX_PERCENTILE(total_elapsed_time, 0.95) AS p95_total_duration_ms,
       MAX(src.source_p95_total_duration_ms) AS source_p95_total_duration_ms
FROM tagged
LEFT JOIN src USING (source_kind)
GROUP BY warehouse_id, identity_type, user_name, source_kind, job_id
ORDER BY compute_type, source_kind, query_count DESC
