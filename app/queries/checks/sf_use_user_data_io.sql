-- query_id: sf_use_user_data_io
-- title: Which users and roles read, write and change the most data objects
-- domain: governance_access   tier: standard
-- entity: users and roles = row_level, user_name, role_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 500) users and roles kept, each ranked by queries that touched data objects
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user (row_level = user) or one role (row_level = role), the top_n busiest of
--   each. read_queries, write_queries and ddl_queries count distinct queries that read, wrote or changed
--   a data object; data_queries counts distinct queries that did any of the three, so the kinds can add
--   up to more than data_queries. tables_read / tables_written count distinct table-like objects (base,
--   dynamic, Iceberg and external tables, materialized views); objects_ddl counts any object type changed.
--   databases_touched counts databases of the tables and views used. users (role rows) are distinct users
--   who used the role; roles_used (user rows) are distinct roles the user used. top_tables lists up to 5
--   table names by queries. service_query_pct (role rows) is the share of the role's queries run by
--   service users. activity_rank orders by data_queries within the row level (1 = busiest).
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window (Standard edition, or the
--   role cannot see it), so who used what cannot be told from nobody using it
-- healthy: status = OK for every ranked row; this check describes use and flags nothing. NOT_ASSESSED when
--   ACCESS_HISTORY is empty.
-- investigate_if: NOT_ASSESSED (no_access_history) means ACCESS_HISTORY has no rows in the window, so
--   check the edition and the role's access to the SNOWFLAKE database.
-- actions: 1) none needed for OK rows (free); 2) when a service user or role dominates, confirm that is the
--   intended pipeline (free).
-- next: none
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- caveats: ACCESS_HISTORY needs Enterprise edition and lags up to 3 hours; reads by data-sharing consumers
--   and replication are not in it. Counts only queries that touched data objects; sf_use_user_activity
--   counts every statement, credits and idle users holding roles. Roles come from QUERY_HISTORY, so
--   queries missing there have no role row. databases_touched splits the name on the first dot, so a
--   quoted database name containing a dot is counted wrongly. Columns are named for objects, never
--   people, in top_tables.
WITH __INCLUDE_sf_use_access_events__,
__INCLUDE_sf_use_query_roles__,
__INCLUDE_sf_sec_users__,
seen AS (
  SELECT access_rows FROM sf_use_access_seen
),
rl AS (
  SELECT name AS role_name, MIN(TO_VARCHAR(role_id)) AS role_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL AND role_type = 'ROLE'
  GROUP BY name
),
ev AS (
  SELECT e.*, r.role_name, COALESCE(u.user_type, 'UNKNOWN') AS user_type, u.user_id,
         COALESCE(u.user_type, '') IN ('SERVICE', 'LEGACY_SERVICE') AS is_service_user
  FROM sf_use_access_events e
  LEFT JOIN sf_use_query_roles r ON r.query_id = e.query_id
  LEFT JOIN sf_sec_users u ON u.user_name = e.user_name
),
-- every event once for its user and once for its role; each distinct below is counted per principal
p AS (
  SELECT 'user' AS row_level, user_name AS pkey, ev.* FROM ev
  UNION ALL
  SELECT 'role', role_name, ev.* FROM ev WHERE role_name IS NOT NULL
),
a AS (
  SELECT row_level, pkey,
         MAX(IFF(row_level = 'user', user_id, NULL)) AS user_id,
         MAX(IFF(row_level = 'user', user_type, NULL)) AS user_type,
         MAX(IFF(row_level = 'user', is_service_user, NULL)) AS is_service_user,
         IFF(row_level = 'role', COUNT(DISTINCT user_name), 1) AS users,
         IFF(row_level = 'user', COUNT(DISTINCT role_name), NULL) AS roles_used,
         COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries,
         COUNT(DISTINCT query_id) AS data_queries,
         COUNT(DISTINCT IFF(is_table_like AND kind = 'read', object_id, NULL)) AS tables_read,
         COUNT(DISTINCT IFF(is_table_like AND kind = 'write', object_id, NULL)) AS tables_written,
         COUNT(DISTINCT IFF(kind = 'ddl', object_domain || '|' || COALESCE(TO_VARCHAR(object_id), object_name), NULL)) AS objects_ddl,
         COUNT(DISTINCT IFF(is_table_like OR UPPER(object_domain) = 'VIEW', SPLIT_PART(object_name, '.', 1), NULL)) AS databases_touched,
         COUNT(DISTINCT usage_date) AS active_days,
         MAX(query_start_time) AS last_activity_at,
         IFF(row_level = 'role',
             100 * COUNT(DISTINCT IFF(is_service_user, query_id, NULL)) / NULLIF(COUNT(DISTINCT query_id), 0),
             NULL) AS service_query_pct
  FROM p
  GROUP BY row_level, pkey
),
tq AS (
  SELECT row_level, pkey, object_id, MAX(object_name) AS object_name, COUNT(DISTINCT query_id) AS q
  FROM p
  WHERE is_table_like
  GROUP BY row_level, pkey, object_id
),
tt AS (
  SELECT row_level, pkey,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(object_name) WITHIN GROUP (ORDER BY q DESC, object_name), 0, 5), ', ') AS top_tables
  FROM tq
  GROUP BY row_level, pkey
),
s AS (
  SELECT a.*, tt.top_tables,
         RANK() OVER (PARTITION BY a.row_level ORDER BY a.data_queries DESC) AS activity_rank,
         ROW_NUMBER() OVER (PARTITION BY a.row_level ORDER BY a.data_queries DESC, a.pkey) AS rn
  FROM a
  LEFT JOIN tt ON tt.row_level = a.row_level AND tt.pkey = a.pkey
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, s.row_level,
       IFF(s.row_level = 'user', s.pkey, NULL) AS user_name, s.user_id, s.user_type, s.is_service_user,
       IFF(s.row_level = 'role', s.pkey, NULL) AS role_name,
       IFF(s.row_level = 'role', rl.role_id, NULL) AS role_id,
       s.users, s.roles_used, s.read_queries, s.write_queries, s.ddl_queries, s.data_queries,
       s.tables_read, s.tables_written, s.objects_ddl, s.databases_touched, s.active_days,
       s.last_activity_at, s.top_tables, s.service_query_pct, s.activity_rank,
       CAST(NULL AS VARCHAR) AS not_assessed_reason, 'OK' AS status
FROM s
LEFT JOIN rl ON rl.role_name = s.pkey
WHERE s.rn <= :top_n
UNION ALL
SELECT :period_days, __ACCOUNT_ID__, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, CAST(NULL AS TIMESTAMP_NTZ),
       CAST(NULL AS VARCHAR), NULL, NULL, 'no_access_history', 'NOT_ASSESSED'
FROM seen
WHERE access_rows = 0
ORDER BY row_level NULLS LAST, activity_rank
