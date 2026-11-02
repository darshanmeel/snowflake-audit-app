-- query_id: sf_use_table_readers
-- title: Who reads and writes the busiest tables, by user and role
-- domain: governance_access   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 100) tables: only the busiest tables by query count are listed; :top_users
--   (default 25) users: at most this many user x role rows per table
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user x role on one of the :top_n busiest tables in the window. table_rank 1 =
--   most queries; each table keeps its busiest :top_users rows (row_rank_in_table 1 = most queries). read_queries,
--   write_queries and ddl_queries count distinct queries that touched the table, also through views;
--   table_users is the exact number of distinct users on the table, even when its rows are cut at
--   :top_users. user_type is the user's type today (UNKNOWN for a dropped or Snowflake-managed user);
--   is_service_user marks SERVICE and LEGACY_SERVICE users.
-- healthy: status = OK on every listed row; this check shows who uses a table, it does not judge it.
-- investigate_if: NOT_ASSESSED when ACCESS_HISTORY has no rows in the window.
-- actions: 1) check that each user and role on a busy table still needs it; revoke the role otherwise
--   (free); 2) move person users off service-only tables, or give shared pipelines their own role
--   (config).
-- next: none
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window (Standard edition, or the
--   role cannot see it), so who used a table cannot be told from nobody using it
-- caveats: the role is the query's primary role (secondary roles are not split out); ACCESS_HISTORY lags up
--   to 3 hours and QUERY_HISTORY up to 45 minutes; user_type is today's USERS.TYPE, not the type at query
--   time. A table dropped or replaced in the window keeps its row under the upper-cased name from
--   ACCESS_HISTORY. Reads by data-sharing consumers and replication are not in ACCESS_HISTORY.
WITH -- ACCESS_HISTORY flattened to one event per query x object x kind (read, write, ddl). Columns: query_id,
-- query_start_time, usage_date, user_name, kind, object_domain, object_id, object_name, is_table_like,
-- ddl_operation. sf_use_access_seen holds access_rows. Only ids, names and the DDL operation, never query text.
sf_use_ah AS (
  SELECT ah.query_id, ah.query_start_time, ah.user_name, ah.base_objects_accessed, ah.direct_objects_accessed,
         ah.objects_modified, ah.object_modified_by_ddl
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
sf_use_raw AS (
  SELECT a.query_id, a.query_start_time, a.user_name, 'read' AS kind,
         UPPER(f.value:"objectDomain"::STRING) AS object_domain, f.value:"objectId"::NUMBER AS object_id,
         UPPER(f.value:"objectName"::STRING) AS object_name, CAST(NULL AS VARCHAR) AS ddl_operation
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'read',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER,
         UPPER(f.value:"objectName"::STRING), CAST(NULL AS VARCHAR)
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.direct_objects_accessed) f
  -- table-like objects are already in base_objects_accessed; views, stages, functions, streams are not
  WHERE UPPER(f.value:"objectDomain"::STRING) NOT IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE',
                                                       'EXTERNAL TABLE', 'MATERIALIZED VIEW')
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'write',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER,
         UPPER(f.value:"objectName"::STRING), CAST(NULL AS VARCHAR)
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.objects_modified) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'ddl',
         UPPER(COALESCE(a.object_modified_by_ddl:"objectDomain"::STRING, 'UNKNOWN')),
         a.object_modified_by_ddl:"objectId"::NUMBER,
         UPPER(a.object_modified_by_ddl:"objectName"::STRING),
         UPPER(a.object_modified_by_ddl:"operationType"::STRING)
  FROM sf_use_ah a
  WHERE a.object_modified_by_ddl IS NOT NULL
),
sf_use_raw_t AS (
  SELECT r.*, r.object_domain IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'EXTERNAL TABLE',
                                  'MATERIALIZED VIEW') AS is_table_like
  FROM sf_use_raw r
),
sf_use_events AS (
  SELECT DISTINCT r.query_id, r.query_start_time, DATE(r.query_start_time) AS usage_date, r.user_name, r.kind,
         r.object_domain, r.object_id, r.object_name, r.is_table_like, r.ddl_operation
  FROM sf_use_raw_t r
  -- a MERGE or INSERT ... SELECT from itself is a write, not a read of its target
  LEFT JOIN sf_use_raw_t w
    ON r.kind = 'read' AND w.kind = 'write' AND w.query_id = r.query_id
   AND w.is_table_like = r.is_table_like AND w.object_id = r.object_id
  WHERE w.query_id IS NULL
),
sf_use_access_seen AS (
  SELECT COUNT(*) AS access_rows FROM sf_use_ah
),
sf_use_access_events AS (
  SELECT * FROM sf_use_events
),
-- One role per query in the window: MAX(role_name) from QUERY_HISTORY, limited to the queries in ACCESS_HISTORY.
sf_use_query_roles AS (
  SELECT q.query_id, MAX(UPPER(q.role_name)) AS role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  WHERE q.start_time >= DATEADD(day, -(:period_days + 1), __AS_OF_DATE__)
    AND q.query_id IN (SELECT query_id FROM sf_use_ah)
  GROUP BY q.query_id
),
-- Live users with the auth flags normalised: DISABLED and EXT_AUTHN_DUO can come back as VARIANT
-- text, and a NULL TYPE behaves as PERSON.
sf_sec_users AS (
  SELECT TO_VARCHAR(user_id) AS user_id, name AS user_name, email, created_on,
         COALESCE(UPPER(type), 'PERSON') AS user_type,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE) AS is_disabled,
         COALESCE(has_password, FALSE) AS has_password,
         COALESCE(has_mfa, FALSE) AS has_mfa,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(ext_authn_duo)), FALSE) AS has_duo,
         COALESCE(has_rsa_public_key, FALSE) AS has_rsa_key,
         UPPER(default_role) AS default_role, UPPER(default_secondary_role) AS default_secondary_role,
         last_success_login, password_last_set_time, locked_until_time, owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  -- Snowflake-managed users (SNOWFLAKE, WORKSHEETS_APP_USER) are not the customer's to change.
  WHERE deleted_on IS NULL AND COALESCE(UPPER(type), '') <> 'SNOWFLAKE_SERVICE'
    AND UPPER(name) NOT IN ('SNOWFLAKE', 'WORKSHEETS_APP_USER')
),
-- Live tables with their current storage split: TABLE_STORAGE_METRICS holds the bytes, TABLES the
-- settings. The YES/NO text flags are turned into booleans so every storage check reads them alike.
sf_storage_live_tables AS (
  SELECT m.id AS table_id, m.table_catalog AS database_name, m.table_catalog_id AS database_id,
         m.table_schema AS schema_name, m.table_schema_id AS schema_id, m.table_name,
         m.table_catalog || '.' || m.table_schema || '.' || m.table_name AS table_fqn,
         m.clone_group_id,
         COALESCE(m.active_bytes, 0) AS active_bytes,
         COALESCE(m.time_travel_bytes, 0) AS time_travel_bytes,
         COALESCE(m.failsafe_bytes, 0) AS failsafe_bytes,
         COALESCE(m.retained_for_clone_bytes, 0) AS retained_for_clone_bytes,
         COALESCE(m.active_bytes, 0) + COALESCE(m.time_travel_bytes, 0) + COALESCE(m.failsafe_bytes, 0)
           + COALESCE(m.retained_for_clone_bytes, 0) AS total_bytes,
         -- no TABLES row would make this NULL and drop the table from NOT is_transient filters
         COALESCE(m.is_transient = 'YES' OR t.is_transient = 'YES', m.is_transient = 'YES', FALSE) AS is_transient,
         COALESCE(t.table_type, 'BASE TABLE') AS table_type,
         t.retention_time, t.clustering_key,
         COALESCE(t.auto_clustering_on = 'YES', FALSE) AS auto_clustering_on,
         COALESCE(t.is_iceberg = 'YES', FALSE) AS is_iceberg,
         COALESCE(t.is_dynamic = 'YES', FALSE) AS is_dynamic,
         COALESCE(t.is_hybrid = 'YES', FALSE) AS is_hybrid,
         t.row_count, t.bytes AS table_bytes, t.table_owner, t.created, t.last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS m
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t ON t.table_id = m.id AND t.deleted IS NULL
  -- Fail-safe rows have NULL names (and can carry deleted = FALSE): they are not live tables.
  WHERE NOT COALESCE(m.deleted, FALSE) AND m.table_dropped IS NULL
    AND m.schema_dropped IS NULL AND m.catalog_dropped IS NULL
    AND m.table_name IS NOT NULL AND m.table_entered_failsafe IS NULL
),
ev AS (
  SELECT e.object_id, e.object_name, e.user_name, e.query_id, e.kind, e.usage_date, e.query_start_time,
         COALESCE(q.role_name, '(unknown role)') AS role_name
  FROM sf_use_access_events e
  LEFT JOIN sf_use_query_roles q ON q.query_id = e.query_id
  WHERE e.is_table_like AND e.object_id IS NOT NULL
),
tr AS (
  SELECT object_id, COUNT(DISTINCT query_id) AS table_queries, COUNT(DISTINCT user_name) AS table_users,
         ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT query_id) DESC, object_id) AS table_rank
  FROM ev
  GROUP BY object_id
),
g AS (
  SELECT ev.object_id, MAX(ev.object_name) AS object_name, ev.user_name, ev.role_name,
         COUNT(DISTINCT IFF(ev.kind = 'read', ev.query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(ev.kind = 'write', ev.query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(ev.kind = 'ddl', ev.query_id, NULL)) AS ddl_queries,
         COUNT(DISTINCT ev.usage_date) AS active_days,
         MIN(ev.query_start_time) AS first_at, MAX(ev.query_start_time) AS last_at
  FROM ev
  JOIN tr ON tr.object_id = ev.object_id AND tr.table_rank <= :top_n
  GROUP BY ev.object_id, ev.user_name, ev.role_name
),
ranked AS (
  SELECT g.*, ROW_NUMBER() OVER (PARTITION BY g.object_id
           ORDER BY g.read_queries + g.write_queries + g.ddl_queries DESC, g.user_name, g.role_name) AS row_rank_in_table
  FROM g
),
seen AS (
  SELECT access_rows FROM sf_use_access_seen
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       COALESCE(l.database_name, SPLIT_PART(r.object_name, '.', 1)) AS database_name,
       COALESCE(l.schema_name, SPLIT_PART(r.object_name, '.', 2)) AS schema_name,
       COALESCE(l.table_name, SPLIT_PART(r.object_name, '.', 3)) AS table_name,
       r.object_id AS table_id,
       COALESCE(l.table_fqn, r.object_name) AS table_fqn,
       tr.table_rank, tr.table_users, r.user_name,
       COALESCE(u.user_type, 'UNKNOWN') AS user_type,
       COALESCE(u.user_type, 'UNKNOWN') IN ('SERVICE', 'LEGACY_SERVICE') AS is_service_user,
       r.role_name, r.read_queries, r.write_queries, r.ddl_queries, r.active_days, r.first_at, r.last_at,
       r.row_rank_in_table, CAST(NULL AS VARCHAR) AS not_assessed_reason, 'OK' AS status
FROM ranked r
JOIN tr ON tr.object_id = r.object_id
LEFT JOIN sf_sec_users u ON u.user_name = r.user_name
LEFT JOIN sf_storage_live_tables l ON l.table_id = r.object_id
WHERE r.row_rank_in_table <= :top_users
UNION ALL
SELECT :period_days, __ACCOUNT_ID__, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN), CAST(NULL AS VARCHAR),
       CAST(NULL AS INTEGER), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER),
       CAST(NULL AS TIMESTAMP), CAST(NULL AS TIMESTAMP), CAST(NULL AS INTEGER),
       'no_access_history', 'NOT_ASSESSED'
FROM seen WHERE access_rows = 0
ORDER BY table_rank, row_rank_in_table
