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
WITH __INCLUDE_sf_use_access_rows__
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
