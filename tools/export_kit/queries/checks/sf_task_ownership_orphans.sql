-- query_id: sf_task_ownership_orphans
-- title: Tasks whose owner role no longer exists
-- domain: jobs_pipelines   tier: standard
-- windowed: no
-- pre: SHOW TASKS IN ACCOUNT
-- reads: SHOW TASKS IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :warn_orphan_tasks (default 5) tasks whose owner role no longer exists, in the account, that
--   flags WARN; :crit_orphan_tasks (default 20) that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = the account. The columns that matter are tasks_owner_role_missing (tasks whose
--   owner role has been dropped, so nobody can manage them and they may fail or run under a role that
--   no longer holds the grants they need) and tasks_owner_not_recorded (shown for context, not
--   scored).
-- healthy: tasks_owner_role_missing is 0 - every task is owned by a role that still exists.
-- investigate_if: tasks_owner_role_missing at/above :warn_orphan_tasks (WARN) or :crit_orphan_tasks
--   (CRITICAL). NOT_ASSESSED when no task has an owner recorded. This is a governance signal, not a
--   cost figure.
-- actions: 1) list the tasks with SHOW TASKS and give each a live owner with GRANT OWNERSHIP (free);
--   2) move the task graph to a service role that is not tied to one person (config); 3) drop tasks
--   nobody needs (free).
-- next: none
-- caveats: a task runs with its owner role's privileges. SHOW TASKS lists only live tasks the audit
--   role can see, so dropped tasks never count; tasks the role cannot see are not judged.
WITH tasks AS (
  SELECT s."id" AS id, s."owner" AS owner
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
),
live_roles AS (
  SELECT DISTINCT name FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES WHERE deleted_on IS NULL
),
judged AS (
  SELECT t.id, NULLIF(TRIM(t.owner), '') AS owner, r.name IS NOT NULL AS owner_exists
  FROM tasks t
  LEFT JOIN live_roles r ON r.name = t.owner
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       COUNT(*) AS tasks,
       COUNT_IF(owner IS NOT NULL AND owner_exists) AS tasks_with_live_owner_role,
       COUNT_IF(owner IS NOT NULL AND NOT owner_exists) AS tasks_owner_role_missing,
       COUNT_IF(owner IS NULL) AS tasks_owner_not_recorded,
       IFF(COUNT(*) = COUNT_IF(owner IS NULL), 'owner_not_recorded', NULL) AS not_assessed_reason,
       CASE
         WHEN COUNT(*) = COUNT_IF(owner IS NULL) THEN 'NOT_ASSESSED'
         WHEN COUNT_IF(owner IS NOT NULL AND NOT owner_exists) >= :crit_orphan_tasks THEN 'CRITICAL'
         WHEN COUNT_IF(owner IS NOT NULL AND NOT owner_exists) >= :warn_orphan_tasks THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM judged
HAVING COUNT(*) > 0
