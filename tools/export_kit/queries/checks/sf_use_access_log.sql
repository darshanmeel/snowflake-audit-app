-- query_id: sf_use_access_log
-- title: Who read or changed each table, view and stage, when and how often
-- domain: governance_access   tier: standard
-- entity: objects = object_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition
-- params: :lookback_days (default 90) days of ACCESS_HISTORY it reads, counted back from the export date;
--   :bucket_hours (default 24) hours per row: 24 counts per UTC day, 1 per UTC hour (up to 24 times the rows);
--   :row_cap (default 1000000) rows: the export keeps at most this many, newest buckets first
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one object x user x role x client x statement type x UTC day (or hour). Every table,
--   view, stage and other object in ACCESS_HISTORY is kept, not only the busy ones. read_queries,
--   write_queries and ddl_queries count distinct queries; reads through a view count on the view and on
--   its base tables. client is the first word of the session's client application (Snowflake UI, JDBC,
--   PythonConnector, ODBC ...), task for tasks and no session when SESSIONS has none. statement_type is
--   the QUERY_HISTORY query type (SELECT, INSERT, MERGE, CREATE_TABLE_AS_SELECT ...) and ddl_operations
--   the DDL operations (CREATE, ALTER, DROP, RENAME ...). user_type is the user's TYPE today (NOT_SET when
--   it has none, UNKNOWN when dropped). No query text or query id is kept: the page has the SQL to list
--   the queries of one object. Off-hours use by people is in sf_use_access_hours.
-- healthy: status = OK on every row; this check is a log, it does not judge.
-- investigate_if: NOT_ASSESSED when ACCESS_HISTORY has no rows in the lookback.
-- actions: 1) check that each user and role reading a sensitive object needs it; revoke the role
--   otherwise (free); 2) list the single queries of one object with the SQL on the page (free)
-- next: sf_use_access_hours
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the lookback (Standard edition, or
--   the role cannot see it), so who used an object cannot be told from nobody using it
-- caveats: ACCESS_HISTORY lags up to 3 hours and skips failed queries, reader accounts and data-sharing
--   consumers. The role is the query's primary role. Days and hours are UTC. Downloads of query results
--   (Snowsight, drivers) are not logged by Snowflake; GET and unloads are in sf_gov_file_downloads.
WITH -- ACCESS_HISTORY over :lookback_days flattened to one event per query x object x kind (read, write, ddl),
-- with the query's role and statement type, its session's client and the user's TYPE today. Columns of
-- sf_acc_rows: query_id, query_start_time (UTC), user_name, kind, object_domain, object_id, object_name,
-- ddl_operation, statement_type, role_name, client, user_type. sf_acc_seen holds access_rows.
-- Only ids, names and types, never query text.
sf_acc_ah AS (
  SELECT query_id, query_start_time, user_name, base_objects_accessed, direct_objects_accessed,
         objects_modified, object_modified_by_ddl
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
    AND query_start_time < __AS_OF_DATE__
),
sf_acc_raw AS (
  SELECT a.query_id, a.query_start_time, a.user_name, 'read' AS kind,
         UPPER(f.value:"objectDomain"::STRING) AS object_domain, f.value:"objectId"::NUMBER AS object_id,
         UPPER(f.value:"objectName"::STRING) AS object_name, CAST(NULL AS VARCHAR) AS ddl_operation
  FROM sf_acc_ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  -- views, stages and functions read directly; base tables are already above
  SELECT a.query_id, a.query_start_time, a.user_name, 'read',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER, UPPER(f.value:"objectName"::STRING),
         CAST(NULL AS VARCHAR)
  FROM sf_acc_ah a, LATERAL FLATTEN(input => a.direct_objects_accessed) f
  WHERE UPPER(f.value:"objectDomain"::STRING) NOT IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE',
                                                       'EXTERNAL TABLE', 'MATERIALIZED VIEW')
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'write',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER, UPPER(f.value:"objectName"::STRING),
         CAST(NULL AS VARCHAR)
  FROM sf_acc_ah a, LATERAL FLATTEN(input => a.objects_modified) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'ddl',
         UPPER(COALESCE(a.object_modified_by_ddl:"objectDomain"::STRING, 'UNKNOWN')),
         a.object_modified_by_ddl:"objectId"::NUMBER, UPPER(a.object_modified_by_ddl:"objectName"::STRING),
         UPPER(a.object_modified_by_ddl:"operationType"::STRING)
  FROM sf_acc_ah a
  WHERE a.object_modified_by_ddl IS NOT NULL
),
sf_acc_qh AS (
  SELECT query_id, MAX(UPPER(role_name)) AS role_name, MAX(session_id) AS session_id, MAX(query_type) AS query_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -(:lookback_days + 1), __AS_OF_DATE__)
    AND query_id IN (SELECT query_id FROM sf_acc_ah)
  GROUP BY query_id
),
sf_acc_ss AS (
  SELECT session_id, MAX(SPLIT_PART(client_application_id, ' ', 1)) AS client
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  -- a margin for sessions opened before the lookback; without a bound Snowflake scans a year of sessions
  WHERE created_on >= DATEADD(day, -(:lookback_days + 7), __AS_OF_DATE__)
    AND session_id IN (SELECT session_id FROM sf_acc_qh)
  GROUP BY session_id
),
sf_acc_ut AS (
  -- the raw TYPE: older service users often have none, and must not read as people
  SELECT name AS user_name, COALESCE(UPPER(type), 'NOT_SET') AS user_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL
),
sf_acc_rows AS (
  SELECT DISTINCT r.query_id, r.query_start_time, r.user_name, r.kind, r.object_domain, r.object_id, r.object_name,
         r.ddl_operation, COALESCE(q.query_type, 'UNKNOWN') AS statement_type,
         COALESCE(q.role_name, '(unknown role)') AS role_name,
         -- tasks run as SYSTEM with no session; other queries without one are said so, not "unknown"
         COALESCE(NULLIF(s.client, ''), IFF(r.user_name = 'SYSTEM', 'task', 'no session')) AS client,
         COALESCE(u.user_type, 'UNKNOWN') AS user_type
  FROM sf_acc_raw r
  -- a MERGE or INSERT ... SELECT from itself is a write, not a read of its target
  LEFT JOIN sf_acc_raw w ON r.kind = 'read' AND w.kind = 'write' AND w.query_id = r.query_id AND w.object_id = r.object_id
  LEFT JOIN sf_acc_qh q ON q.query_id = r.query_id
  LEFT JOIN sf_acc_ss s ON s.session_id = q.session_id
  LEFT JOIN sf_acc_ut u ON u.user_name = r.user_name
  WHERE r.object_name IS NOT NULL AND w.query_id IS NULL
),
sf_acc_seen AS (
  SELECT COUNT(*) AS access_rows FROM sf_acc_ah
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, IFF(:bucket_hours = 1, 'hour', 'day') AS grain,
       IFF(:bucket_hours = 1, DATE_TRUNC('hour', e.query_start_time), DATE_TRUNC('day', e.query_start_time))::TIMESTAMP_NTZ AS bucket_start,
       e.object_domain, e.object_id,
       SPLIT_PART(MAX(e.object_name), '.', 1) AS database_name, SPLIT_PART(MAX(e.object_name), '.', 2) AS schema_name,
       MAX(e.object_name) AS object_fqn, e.user_name, MAX(e.user_type) AS user_type,
       MAX(e.user_type) = 'PERSON' AND e.user_name <> 'SYSTEM' AS is_person,
       e.role_name, e.client, e.statement_type,
       COUNT(DISTINCT IFF(e.kind = 'read', e.query_id, NULL)) AS read_queries,
       COUNT(DISTINCT IFF(e.kind = 'write', e.query_id, NULL)) AS write_queries,
       COUNT(DISTINCT IFF(e.kind = 'ddl', e.query_id, NULL)) AS ddl_queries,
       LISTAGG(DISTINCT e.ddl_operation, ', ') WITHIN GROUP (ORDER BY e.ddl_operation) AS ddl_operations,
       MIN(e.query_start_time)::TIMESTAMP_NTZ AS first_at, MAX(e.query_start_time)::TIMESTAMP_NTZ AS last_at,
       CAST(NULL AS VARCHAR) AS not_assessed_reason, 'OK' AS status
FROM sf_acc_rows e
-- object_id keeps a dropped and a re-created table apart; a NULL id (some stages) groups by name
GROUP BY IFF(:bucket_hours = 1, DATE_TRUNC('hour', e.query_start_time), DATE_TRUNC('day', e.query_start_time)),
         e.object_domain, e.object_id, IFF(e.object_id IS NULL, e.object_name, NULL), e.user_name, e.role_name,
         e.client, e.statement_type
UNION ALL
SELECT 0, __ACCOUNT_ID__, IFF(:bucket_hours = 1, 'hour', 'day'), CAST(NULL AS TIMESTAMP_NTZ), CAST(NULL AS VARCHAR),
       CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS INTEGER), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER), CAST(NULL AS VARCHAR),
       CAST(NULL AS TIMESTAMP_NTZ), CAST(NULL AS TIMESTAMP_NTZ), 'no_access_history', 'NOT_ASSESSED'
FROM sf_acc_seen WHERE access_rows = 0
ORDER BY bucket_start DESC NULLS FIRST, object_fqn, user_name
