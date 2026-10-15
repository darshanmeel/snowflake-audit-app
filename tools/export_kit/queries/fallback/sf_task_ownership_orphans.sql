-- query_id: sf_task_ownership_orphans
-- shims: ROLES
-- reads: INFORMATION_SCHEMA table functions SHOW ROLES
-- fallback_note: account roles only (no database or instance roles); the name stands in for the role id
-- pre: SHOW TASKS IN ACCOUNT
WITH tasks AS (
  SELECT s."id" AS id, s."owner" AS owner
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
),
live_roles AS (
  SELECT DISTINCT name FROM __SHIM_ROLES__ WHERE deleted_on IS NULL
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
