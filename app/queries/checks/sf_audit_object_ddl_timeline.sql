-- query_id: sf_audit_object_ddl_timeline
-- title: Who created, changed or dropped which kinds of objects, per day
-- domain: governance_access   tier: standard
-- entity: change groups = usage_date, user_name, role_name, operation, object_domain
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (GOVERNANCE_VIEWER); Enterprise edition
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_drops (default 10) drops: dropping this many objects in one day by one user reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one day x user x role x operation x object kind that recorded DDL touched. The
--   operation is CREATE, ALTER, DROP, UNDROP or REPLACE; the kind is table, view, schema, database,
--   warehouse and so on. objects counts
--   the distinct objects, statements the queries; sample_objects names up to five. Only the operation
--   and the object are read from ACCESS_HISTORY (OBJECT_MODIFIED_BY_DDL): no statement text is stored, so a
--   password in an ALTER USER can never reach the audit. Grants and revokes have their own checks.
-- healthy: status = OK for everyday create and alter work.
-- investigate_if: WARN when one user dropped warn_drops or more objects in a day, or any DDL ran under
--   ACCOUNTADMIN; CRITICAL when a database or a schema was dropped.
-- actions: 1) for a CRITICAL row, confirm with the user and check whether UNDROP is still possible
--   inside Time Travel (free); 2) do day-to-day DDL under a role that owns the objects, not ACCOUNTADMIN
--   (config); 3) route production DDL through a deployment tool so changes carry a change ticket (spend).
-- next: sf_sec_security_config_changes
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- caveats: OBJECT_MODIFIED_BY_DDL is recorded for the object kinds Snowflake supports and records one
--   object per query, so a multi-object statement shows its first. ACCESS_HISTORY needs Enterprise
--   edition, lags up to 3 hours and keeps 365 days. The role is the query's primary role from
--   QUERY_HISTORY (NULL when that row is older than QUERY_HISTORY's retention).
WITH d AS (
  SELECT ah.query_id, ah.query_start_time, ah.user_name,
         COALESCE(ah.object_modified_by_ddl:objectDomain::VARCHAR, 'UNKNOWN') AS object_domain,
         ah.object_modified_by_ddl:objectName::VARCHAR AS object_name,
         UPPER(ah.object_modified_by_ddl:operationType::VARCHAR) AS operation
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
    AND ah.object_modified_by_ddl IS NOT NULL
),
q AS (
  SELECT query_id, MAX(role_name) AS role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY query_id
),
g AS (
  SELECT DATE(d.query_start_time) AS usage_date, d.user_name, COALESCE(q.role_name, '(unknown role)') AS role_name,
         d.operation, UPPER(d.object_domain) AS object_domain,
         COUNT(DISTINCT d.object_name) AS objects, COUNT(DISTINCT d.query_id) AS statements,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT IFF(UPPER(d.object_domain) = 'USER', NULL, d.object_name)), 0, 5), ', ') AS sample_objects,
         MIN(d.query_start_time) AS first_change, MAX(d.query_start_time) AS last_change
  FROM d
  LEFT JOIN q ON q.query_id = d.query_id
  WHERE d.operation IN ('CREATE', 'ALTER', 'DROP', 'UNDROP', 'REPLACE')
  GROUP BY 1, 2, 3, 4, 5
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date, user_name, role_name, operation,
       object_domain, objects, statements, sample_objects, first_change, last_change,
       operation || ' ' || object_domain || ' x ' || objects || ' as ' || role_name AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN operation = 'DROP' AND object_domain IN ('DATABASE', 'SCHEMA') THEN 'CRITICAL'
         WHEN operation = 'DROP' AND objects >= :warn_drops THEN 'WARN'
         WHEN role_name = 'ACCOUNTADMIN' THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY usage_date DESC, CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, objects DESC
