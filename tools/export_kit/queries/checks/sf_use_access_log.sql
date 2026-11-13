-- query_id: sf_use_access_log
-- title: Who read or changed each table, view and stage, when and how often
-- domain: governance_access   tier: standard
-- entity: objects = object_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition
-- params: :lookback_days (default 90) days of ACCESS_HISTORY it reads, counted back from the export date;
--   :grain (default day) day or hour: the time bucket each row counts in (hour gives up to 24 times the rows);
--   :row_cap (default 1000000) rows: the export keeps at most this many, newest buckets first;
--   :business_tz (default UTC) time zone business hours are in (e.g. Europe/Zurich); :business_start_hour
--   (default 7) hour business hours start; :business_end_hour (default 19) hour they end (Saturday and
--   Sunday are off hours all day)
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one object x user x role x client x time bucket (bucket_start, :grain). Every
--   table, view, stage and other object in ACCESS_HISTORY is kept, not only the busy ones. read_queries,
--   write_queries and ddl_queries count distinct queries; reads through a view count on the view and on
--   its base tables. client is the first word of the session's client application (Snowflake UI, JDBC,
--   PythonConnector, ODBC ...), unknown when the session is not in SESSIONS. first_at and last_at are the
--   first and last query in the bucket. statement_types lists the QUERY_HISTORY query types (SELECT, INSERT,
--   MERGE, DELETE, CREATE_TABLE_AS_SELECT ...) and ddl_operations the DDL operations (CREATE, ALTER, DROP,
--   RENAME ...) in the bucket. No query text or query id is kept: the Guide has the SQL to list
--   the queries of one object.
--   off_hours_queries counts the queries outside business hours; user_type is the user's TYPE today
--   (NOT_SET when the user has none, UNKNOWN when dropped) and is_person is TRUE only for TYPE PERSON, so
--   service users, SYSTEM (tasks), users with no type and dropped users are never flagged.
-- healthy: status = OK when people use objects in business hours; service users and pipelines are never
--   flagged.
-- investigate_if: WARN when a person ran queries on the object outside business hours; NOT_ASSESSED when
--   ACCESS_HISTORY has no rows in the lookback.
-- actions: 1) check that each user and role reading a sensitive object needs it; revoke the role
--   otherwise (free); 2) list the single queries of one object with the SQL in the Guide (free)
-- next: sf_gov_sensitive_data_access
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the lookback (Standard edition, or
--   the role cannot see it), so who used an object cannot be told from nobody using it
-- caveats: ACCESS_HISTORY lags up to 3 hours and skips failed queries, reader accounts and data-sharing
--   consumers. The role is the query's primary role. Downloads of query results (Snowsight, drivers) are
--   not logged by Snowflake; GET and unloads are in sf_gov_file_downloads.
WITH ut AS (
  -- the raw TYPE: older service users often have none, and must not read as people
  SELECT name AS user_name, COALESCE(UPPER(type), 'NOT_SET') AS user_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL
),
ah AS (
  SELECT query_id, query_start_time, user_name, base_objects_accessed, direct_objects_accessed,
         objects_modified, object_modified_by_ddl
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
    AND query_start_time < __AS_OF_DATE__
),
raw AS (
  SELECT a.query_id, a.query_start_time, a.user_name, 'read' AS kind,
         UPPER(f.value:"objectDomain"::STRING) AS object_domain, f.value:"objectId"::NUMBER AS object_id,
         UPPER(f.value:"objectName"::STRING) AS object_name, CAST(NULL AS VARCHAR) AS ddl_operation
  FROM ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  -- views, stages and functions read directly; base tables are already above
  SELECT a.query_id, a.query_start_time, a.user_name, 'read',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER, UPPER(f.value:"objectName"::STRING),
         CAST(NULL AS VARCHAR)
  FROM ah a, LATERAL FLATTEN(input => a.direct_objects_accessed) f
  WHERE UPPER(f.value:"objectDomain"::STRING) NOT IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE',
                                                       'EXTERNAL TABLE', 'MATERIALIZED VIEW')
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'write',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER, UPPER(f.value:"objectName"::STRING),
         CAST(NULL AS VARCHAR)
  FROM ah a, LATERAL FLATTEN(input => a.objects_modified) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'ddl',
         UPPER(COALESCE(a.object_modified_by_ddl:"objectDomain"::STRING, 'UNKNOWN')),
         a.object_modified_by_ddl:"objectId"::NUMBER, UPPER(a.object_modified_by_ddl:"objectName"::STRING),
         UPPER(a.object_modified_by_ddl:"operationType"::STRING)
  FROM ah a
  WHERE a.object_modified_by_ddl IS NOT NULL
),
qh AS (
  SELECT q.query_id, MAX(UPPER(q.role_name)) AS role_name, MAX(q.session_id) AS session_id,
         MAX(q.query_type) AS query_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  WHERE q.start_time >= DATEADD(day, -(:lookback_days + 1), __AS_OF_DATE__)
    AND q.query_id IN (SELECT query_id FROM ah)
  GROUP BY q.query_id
),
ss AS (
  SELECT session_id, MAX(SPLIT_PART(client_application_id, ' ', 1)) AS client
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  -- a margin for sessions opened before the lookback; without a bound Snowflake scans a year of sessions
  WHERE created_on >= DATEADD(day, -(:lookback_days + 7), __AS_OF_DATE__)
    AND session_id IN (SELECT session_id FROM qh)
  GROUP BY session_id
),
ev AS (
  SELECT DISTINCT r.query_id, r.query_start_time, r.user_name, r.kind, r.object_domain, r.object_id, r.object_name,
         r.ddl_operation, q.query_type,
         COALESCE(q.role_name, '(unknown role)') AS role_name, COALESCE(NULLIF(s.client, ''), 'unknown') AS client,
         DAYOFWEEKISO(CONVERT_TIMEZONE(:business_tz, r.query_start_time)) >= 6
           OR HOUR(CONVERT_TIMEZONE(:business_tz, r.query_start_time)) < :business_start_hour
           OR HOUR(CONVERT_TIMEZONE(:business_tz, r.query_start_time)) >= :business_end_hour AS is_off_hours
  FROM raw r
  -- a MERGE or INSERT ... SELECT from itself is a write, not a read of its target
  LEFT JOIN raw w ON r.kind = 'read' AND w.kind = 'write' AND w.query_id = r.query_id AND w.object_id = r.object_id
  LEFT JOIN qh q ON q.query_id = r.query_id
  LEFT JOIN ss s ON s.session_id = q.session_id
  WHERE r.object_name IS NOT NULL AND w.query_id IS NULL
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM ah
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, :grain AS grain,
       DATE_TRUNC(:grain, ev.query_start_time)::TIMESTAMP_NTZ AS bucket_start,
       ev.object_domain, ev.object_id,
       SPLIT_PART(MAX(ev.object_name), '.', 1) AS database_name, SPLIT_PART(MAX(ev.object_name), '.', 2) AS schema_name,
       MAX(ev.object_name) AS object_fqn, ev.user_name, ev.role_name, ev.client,
       COUNT(DISTINCT IFF(ev.kind = 'read', ev.query_id, NULL)) AS read_queries,
       COUNT(DISTINCT IFF(ev.kind = 'write', ev.query_id, NULL)) AS write_queries,
       COUNT(DISTINCT IFF(ev.kind = 'ddl', ev.query_id, NULL)) AS ddl_queries,
       COUNT(DISTINCT IFF(ev.is_off_hours, ev.query_id, NULL)) AS off_hours_queries,
       MAX(COALESCE(u.user_type, 'UNKNOWN')) AS user_type,
       COALESCE(BOOLOR_AGG(u.user_type = 'PERSON' AND ev.user_name <> 'SYSTEM'), FALSE) AS is_person,
       LISTAGG(DISTINCT ev.query_type, ', ') WITHIN GROUP (ORDER BY ev.query_type) AS statement_types,
       LISTAGG(DISTINCT ev.ddl_operation, ', ') WITHIN GROUP (ORDER BY ev.ddl_operation) AS ddl_operations,
       MIN(ev.query_start_time)::TIMESTAMP_NTZ AS first_at, MAX(ev.query_start_time)::TIMESTAMP_NTZ AS last_at,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(COALESCE(BOOLOR_AGG(u.user_type = 'PERSON' AND ev.user_name <> 'SYSTEM'), FALSE)
           AND COUNT(DISTINCT IFF(ev.is_off_hours, ev.query_id, NULL)) > 0, 'WARN', 'OK') AS status
FROM ev
LEFT JOIN ut u ON u.user_name = ev.user_name
-- object_id keeps a dropped and a re-created table apart; a NULL id (some stages) groups by name
GROUP BY DATE_TRUNC(:grain, ev.query_start_time), ev.object_domain, ev.object_id,
         IFF(ev.object_id IS NULL, ev.object_name, NULL), ev.user_name, ev.role_name, ev.client
UNION ALL
SELECT 0, __ACCOUNT_ID__, :grain, CAST(NULL AS TIMESTAMP_NTZ), CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER),
       CAST(NULL AS INTEGER), CAST(NULL AS INTEGER), CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS TIMESTAMP_NTZ),
       CAST(NULL AS TIMESTAMP_NTZ), 'no_access_history', 'NOT_ASSESSED'
FROM seen WHERE access_rows = 0
ORDER BY bucket_start DESC NULLS FIRST, object_fqn, user_name
