-- query_id: sf_use_object_activity
-- title: Which stages, views, functions, procedures, pipes, tasks and streams are in use
-- domain: governance_access   tier: standard
-- entity: objects = object_domain, object_key
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.VIEWS,
--   SNOWFLAKE.ACCOUNT_USAGE.STAGES, SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS, SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES,
--   SNOWFLAKE.ACCOUNT_USAGE.PIPES, SNOWFLAKE.ACCOUNT_USAGE.TASKS, SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (GOVERNANCE_VIEWER); Enterprise edition for
--   read, write and DDL counts (task runs and pipe loads work on every edition)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 200) objects: the most active objects kept per kind, the kind totals are exact
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Which objectDomain values ACCESS_HISTORY records for
--   functions, procedures and streams is to be confirmed on docs.snowflake.com.
-- read_this: one row = one object, or one object kind as a total row. row_level = object: one stage,
--   view, function, procedure, pipe, task or stream (the top_n most active per kind); read_queries, write_queries and ddl_queries count the queries that
--   read, wrote or changed it (ACCESS_HISTORY), users the distinct people, executions the task runs or
--   the files a pipe loaded. row_level = domain (is_total_row): one row per object kind over all objects,
--   exact, with objects (live count from the inventory, NULL for kinds with no inventory here such as
--   streams, tables, schemas or warehouses) and active_objects (objects with any activity). An object
--   seen in ACCESS_HISTORY but missing from the inventory shows with in_inventory = FALSE (a stream has
--   no ACCOUNT_USAGE view). Procedure overloads are merged into one row per name.
-- healthy: status = OK; this check only shows use and never flags. Unused views are flagged in
--   sf_lin_unused_views, stale pipes in sf_pipe_inactive and stale tasks in sf_task_suspended_or_stale.
-- investigate_if: NOT_ASSESSED when ACCESS_HISTORY has no rows in the window.
-- actions: 1) open the kind with many inactive objects and ask the owners whether they are still needed
--   (free); 2) check the flagging checks named above before dropping anything (free).
-- next: sf_lin_unused_views
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window (Standard edition, or the
--   role cannot see it), so reads, writes and DDL cannot be counted (task and pipe rows keep their runs)
-- caveats: reads, writes and DDL come from ACCESS_HISTORY (Enterprise edition, up to 3 hours late, 365 days
--   kept); a window longer than its history reads as unused. STAGES, PIPES, FUNCTIONS and PROCEDURES show
--   only what the role can see (MANAGE GRANTS does not widen them). Procedure overloads are merged. The include's
--   FLATTENs are not OUTER: a query with no such objects adds no event, which is intended. System objects
--   (SNOWFLAKE.*) are left out of the activity counts. A
--   view read only through a BI extract or a share is invisible here.
WITH __INCLUDE_sf_use_access_events__,
seen AS (
  SELECT access_rows FROM sf_use_access_seen
),
__INCLUDE_sf_use_object_inventory__,
ev1 AS (
  SELECT query_id, user_name, query_start_time, kind, object_id, object_name,
         IFF(UPPER(object_domain) = 'SECURE VIEW', 'VIEW', UPPER(object_domain)) AS object_domain,
         -- a procedure is named with its argument list in ACCESS_HISTORY
         UPPER(REGEXP_REPLACE(object_name, '[(].*$', '')) AS object_fqn
  FROM sf_use_access_events
),
ev0 AS (
  SELECT e.query_id, e.user_name, e.query_start_time, e.kind, e.object_name, e.object_domain,
         IFF(e.object_domain = 'PROCEDURE', e.object_fqn,
             COALESCE(TO_VARCHAR(e.object_id), f.object_key, e.object_fqn)) AS object_key
  FROM ev1 e
  LEFT JOIN inv_fqn f ON f.object_domain = e.object_domain AND f.object_fqn = e.object_fqn
  -- system views are not inventory: keep them out of the counts
  WHERE NOT (e.object_domain IN ('VIEW', 'STAGE', 'FUNCTION', 'PROCEDURE', 'PIPE', 'TASK')
             AND e.object_fqn LIKE 'SNOWFLAKE.%')
),
-- every kind, uncapped: table-like and other kinds feed the kind totals only
ev_all AS (
  SELECT object_domain, object_key, MAX(object_name) AS object_name,
         COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries,
         COUNT(DISTINCT user_name) AS users, MAX(query_start_time) AS last_activity_at
  FROM ev0
  GROUP BY 1, 2
),
dom_ev AS (
  SELECT object_domain,
         COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries,
         COUNT(DISTINCT user_name) AS users, MAX(query_start_time) AS last_activity_at
  FROM ev0
  GROUP BY 1
),
exec AS (
  SELECT 'TASK' AS object_domain, i.object_key, COUNT(*) AS executions
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY th
  JOIN inv i ON i.object_domain = 'TASK'
            AND i.object_fqn = UPPER(th.database_name || '.' || th.schema_name || '.' || th.name)
  WHERE th.scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND th.scheduled_time < __AS_OF_DATE__
    AND th.state IN ('SUCCEEDED', 'FAILED')
  GROUP BY 1, 2
  UNION ALL
  SELECT 'PIPE', TO_VARCHAR(pipe_id), SUM(files_inserted::NUMBER)
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND pipe_id IS NOT NULL
  GROUP BY 1, 2
),
dom_exec AS (
  SELECT 'TASK' AS object_domain, COUNT(*) AS executions
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND state IN ('SUCCEEDED', 'FAILED')
  UNION ALL
  SELECT 'PIPE', SUM(files_inserted::NUMBER)
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
o AS (
  SELECT COALESCE(i.object_domain, e.object_domain) AS object_domain, i.object_subtype,
         COALESCE(i.database_name, SPLIT_PART(e.object_name, '.', 1)) AS database_name,
         COALESCE(i.schema_name, SPLIT_PART(e.object_name, '.', 2)) AS schema_name,
         COALESCE(i.object_name, REGEXP_REPLACE(SPLIT_PART(e.object_name, '.', 3), '[(].*$', '')) AS object_name,
         i.object_id, COALESCE(i.object_key, e.object_key) AS object_key,
         COALESCE(i.object_fqn, UPPER(REGEXP_REPLACE(e.object_name, '[(].*$', ''))) AS object_fqn,
         i.object_owner, i.created, i.last_altered, i.object_key IS NOT NULL AS in_inventory,
         COALESCE(e.read_queries, 0) AS read_queries, COALESCE(e.write_queries, 0) AS write_queries,
         COALESCE(e.ddl_queries, 0) AS ddl_queries, COALESCE(x.executions, 0) AS executions,
         COALESCE(e.users, 0) AS users, e.last_activity_at
  FROM inv i
  FULL OUTER JOIN ev_all e ON e.object_domain = i.object_domain AND e.object_key = i.object_key
  LEFT JOIN exec x ON x.object_domain = COALESCE(i.object_domain, e.object_domain)
                  AND x.object_key = COALESCE(i.object_key, e.object_key)
),
o2 AS (
  SELECT *, (read_queries + write_queries + ddl_queries + executions) > 0 AS is_active,
         ROW_NUMBER() OVER (PARTITION BY object_domain
                            ORDER BY read_queries + write_queries + ddl_queries + executions DESC,
                                     last_altered DESC NULLS LAST, object_key) AS activity_rank
  FROM o
),
kinds AS (
  -- one row per kind; has_inv marks the kinds the inventory covers, so zero stages reads 0, not NULL
  SELECT column1 AS object_domain, TRUE AS has_inv
  FROM VALUES ('VIEW'), ('STAGE'), ('FUNCTION'), ('PROCEDURE'), ('PIPE'), ('TASK')
  UNION
  SELECT DISTINCT object_domain, FALSE FROM o2
  WHERE object_domain NOT IN ('VIEW', 'STAGE', 'FUNCTION', 'PROCEDURE', 'PIPE', 'TASK')
),
dom AS (
  SELECT k.object_domain, k.has_inv, COALESCE(a.inv_objects, 0) AS inv_objects,
         COALESCE(a.active_objects, 0) AS active_objects, COALESCE(x.executions, 0) AS executions
  FROM kinds k
  LEFT JOIN (SELECT object_domain, COUNT_IF(in_inventory) AS inv_objects, COUNT_IF(is_active) AS active_objects
             FROM o2 GROUP BY 1) a ON a.object_domain = k.object_domain
  LEFT JOIN dom_exec x ON x.object_domain = k.object_domain
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, 'object' AS row_level,
       FALSE AS is_total_row, o2.object_domain, o2.object_subtype, o2.database_name, o2.schema_name,
       o2.object_name, o2.object_id, o2.object_key, o2.object_fqn, o2.object_owner, o2.created,
       o2.last_altered, o2.in_inventory,
       CAST(NULL AS NUMBER) AS objects, CAST(NULL AS NUMBER) AS active_objects,
       IFF(s.access_rows = 0, NULL, o2.read_queries) AS read_queries,
       IFF(s.access_rows = 0, NULL, o2.write_queries) AS write_queries,
       IFF(s.access_rows = 0, NULL, o2.ddl_queries) AS ddl_queries,
       o2.executions,
       IFF(s.access_rows = 0, NULL, o2.users) AS users,
       o2.last_activity_at,
       IFF(s.access_rows = 0 AND o2.object_domain NOT IN ('TASK', 'PIPE'), NULL, o2.is_active) AS is_active,
       o2.activity_rank,
       IFF(s.access_rows = 0 AND o2.object_domain NOT IN ('TASK', 'PIPE'), 'no_access_history',
           CAST(NULL AS VARCHAR)) AS not_assessed_reason,
       IFF(s.access_rows = 0 AND o2.object_domain NOT IN ('TASK', 'PIPE'), 'NOT_ASSESSED', 'OK') AS status
FROM o2
CROSS JOIN seen s
WHERE o2.activity_rank <= :top_n
  AND o2.object_domain IN ('VIEW', 'STAGE', 'FUNCTION', 'PROCEDURE', 'STREAM', 'PIPE', 'TASK', 'SEQUENCE',
                           'FILE FORMAT', 'ALERT')
UNION ALL
SELECT :period_days, __ACCOUNT_ID__, 'domain', TRUE, d.object_domain, CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS TIMESTAMP),
       CAST(NULL AS TIMESTAMP), CAST(NULL AS BOOLEAN),
       IFF(d.has_inv, d.inv_objects, CAST(NULL AS NUMBER)),
       IFF(s.access_rows = 0 AND d.object_domain NOT IN ('TASK', 'PIPE'), NULL, d.active_objects),
       IFF(s.access_rows = 0, NULL, COALESCE(v.read_queries, 0)),
       IFF(s.access_rows = 0, NULL, COALESCE(v.write_queries, 0)),
       IFF(s.access_rows = 0, NULL, COALESCE(v.ddl_queries, 0)),
       d.executions,
       IFF(s.access_rows = 0, NULL, COALESCE(v.users, 0)),
       v.last_activity_at, CAST(NULL AS BOOLEAN), CAST(NULL AS NUMBER),
       IFF(s.access_rows = 0 AND d.object_domain NOT IN ('TASK', 'PIPE'), 'no_access_history',
           CAST(NULL AS VARCHAR)),
       IFF(s.access_rows = 0 AND d.object_domain NOT IN ('TASK', 'PIPE'), 'NOT_ASSESSED', 'OK')
FROM dom d
CROSS JOIN seen s
LEFT JOIN dom_ev v ON v.object_domain = d.object_domain
ORDER BY is_total_row DESC, object_domain, activity_rank
