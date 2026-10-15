-- query_id: sf_query_blocked_lock_waits
-- title: Statements blocked waiting on table locks
-- domain: performance   tier: standard
-- entity: locked objects = object_id
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.LOCK_WAIT_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_wait_minutes (default 30) wait minutes: at or above this the row reads WARN;
--   :crit_wait_minutes (default 600) wait minutes: at or above this the row reads CRITICAL;
--   :crit_max_wait_minutes (default 60) max wait minutes: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one locked object (from LOCK_WAIT_HISTORY), plus an '(object not recorded)' row
--   for blocked statements with no lock record. blocked_minutes =
--   QUERY_HISTORY.transaction_blocked_time of the waiting statements; max_wait_minutes = longest single
--   wait; blockers = distinct blocking queries seen.
-- healthy: status = OK when total blocked time stays under warn_wait_minutes
-- investigate_if: WARN when blocked_minutes >= warn_wait_minutes; CRITICAL when >= crit_wait_minutes or
--   one wait >= crit_max_wait_minutes
-- actions: 1) stop concurrent writers to one table (serialize MERGE/UPDATE/DELETE, or write to staging
--   tables and swap) (free); 2) keep transactions short and avoid explicit BEGIN without a fast COMMIT
--   (free); 3) set LOCK_TIMEOUT so blocked jobs fail fast instead of holding a warehouse (config)
-- next: none
-- caveats: a blocked statement keeps its warehouse running while it waits. Lock records may be missing
--   for short waits; those land in the '(object not recorded)' row.
WITH qh AS (
  SELECT query_id, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name, user_name, query_type,
         transaction_blocked_time, start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND transaction_blocked_time > 0
),
lw AS (
  SELECT query_id, TO_VARCHAR(object_id) AS object_id, object_name, lock_type,
         DATEDIFF(second, requested_at, acquired_at) AS wait_s, blocker_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOCK_WAIT_HISTORY
  WHERE requested_at >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__) AND requested_at < __AS_OF_DATE__
),
lwq AS (
  -- one row per waiting query, keeping every locked object it waited on
  SELECT lw.query_id, lw.object_id, lw.object_name, lw.lock_type, lw.wait_s, b.value:query_id::VARCHAR AS blocker_query_id
  FROM lw, LATERAL FLATTEN(input => lw.blocker_queries, outer => TRUE) b
),
j AS (
  SELECT COALESCE(l.object_id, '(none)') AS object_id,
         COALESCE(l.object_name, '(object not recorded)') AS object_name, l.lock_type,
         q.query_id, q.warehouse_id, q.warehouse_name, q.user_name, q.query_type,
         q.transaction_blocked_time, l.wait_s, l.blocker_query_id, q.start_time
  FROM qh q LEFT JOIN lwq l ON l.query_id = q.query_id
),
g AS (
  SELECT object_id, MAX(object_name) AS object_name, MAX(lock_type) AS lock_type,
         COUNT(DISTINCT query_id) AS blocked_statements,
         -- per statement, so a statement blocked by several queries counts its wait once
         SUM(distinct_blocked) AS blocked_ms,
         MAX(GREATEST(COALESCE(wait_s, 0) * 1000, transaction_blocked_time)) / 60000 AS max_wait_minutes,
         COUNT(DISTINCT blocker_query_id) AS blockers,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT user_name), 0, 10), ', ') AS blocked_users,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT warehouse_name), 0, 10), ', ') AS warehouses,
         MODE(query_type) AS main_query_type, MAX(start_time) AS last_seen
  FROM (
    SELECT j.*, IFF(ROW_NUMBER() OVER (PARTITION BY object_id, query_id ORDER BY blocker_query_id) = 1,
                    transaction_blocked_time, 0) AS distinct_blocked
    FROM j
  )
  GROUP BY 1
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, object_id, object_name, lock_type,
       warehouses AS warehouse_name, blocked_statements, blocked_ms / 60000 AS blocked_minutes,
       max_wait_minutes, blockers, blocked_users, main_query_type, last_seen,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN blocked_ms / 60000 >= :crit_wait_minutes OR max_wait_minutes >= :crit_max_wait_minutes THEN 'CRITICAL'
         WHEN blocked_ms / 60000 >= :warn_wait_minutes THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY blocked_minutes DESC
