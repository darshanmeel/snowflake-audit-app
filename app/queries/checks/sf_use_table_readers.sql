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
WITH __INCLUDE_sf_use_access_events__,
__INCLUDE_sf_use_query_roles__,
__INCLUDE_sf_sec_users__,
__INCLUDE_sf_storage_live_tables__,
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
