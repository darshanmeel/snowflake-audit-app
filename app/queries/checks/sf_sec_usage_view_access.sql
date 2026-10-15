-- query_id: sf_sec_usage_view_access
-- title: Who can read the account usage views
-- domain: governance_access   tier: standard
-- entity: roles = role_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :warn_users (default 10) users: total users at or above which the row warns; :critical_users
--   (default 25) users: total users at or above which the row is critical
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account role granted IMPORTED PRIVILEGES on the SNOWFLAKE database or one
--   of its database roles. The database roles are
--   USAGE_VIEWER, GOVERNANCE_VIEWER, SECURITY_VIEWER, OBJECT_VIEWER and ORGANIZATION_*. Those roles read account-wide history, including other users' query text in QUERY_HISTORY.
--   direct_users hold the role itself; total_users also counts enabled users who reach it through roles
--   granted to roles; users is a sample of them.
-- healthy: status = OK when fewer than :warn_users users can use the role. ACCOUNTADMIN holds this access
--   by default, so it is always OK here (its holders are checked in sf_sec_admin_role_holders).
-- investigate_if: WARN at :warn_users or more users, CRITICAL at :critical_users or more, and CRITICAL when
--   PUBLIC holds it (every user can read). Other system roles (SYSADMIN, SECURITYADMIN) are judged by the
--   same counts, as holding it there is not the default.
-- actions: 1) revoke IMPORTED PRIVILEGES and the SNOWFLAKE database roles from roles that do not need
--   account-wide history (free); 2) give analysts one narrow role with just the database role they need,
--   such as USAGE_VIEWER for cost work, and not IMPORTED PRIVILEGES (free); 3) keep QUERY_HISTORY readers
--   to a small named group, since query text can hold sensitive values (config)
-- next: sf_sec_admin_role_holders
-- caveats: Direct grants only to find the roles; users come from the role hierarchy. Database roles from
--   shared databases are not in GRANTS_TO_ROLES. Disabled users are not counted. Lags up to 2 hours.
WITH __INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
holds AS (
  SELECT grantee_name AS role_name,
         COUNT_IF(granted_on = 'DATABASE' AND privilege = 'IMPORTED PRIVILEGES') > 0 AS holds_imported_privileges,
         ARRAY_TO_STRING(ARRAY_SORT(ARRAY_AGG(DISTINCT IFF(granted_on = 'DATABASE_ROLE', SPLIT_PART(name, '.', 2), NULL))), ', ')
           AS database_roles,
         MIN(created_on) AS created_on,
         MIN_BY(granted_by, created_on) AS granted_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on IS NULL AND granted_to IN ('ROLE', 'ACCOUNT ROLE')
    AND ((granted_on = 'DATABASE' AND UPPER(name) = 'SNOWFLAKE' AND privilege = 'IMPORTED PRIVILEGES')
      OR (granted_on = 'DATABASE_ROLE' AND privilege = 'USAGE'
          AND UPPER(name) IN ('SNOWFLAKE.USAGE_VIEWER', 'SNOWFLAKE.GOVERNANCE_VIEWER', 'SNOWFLAKE.SECURITY_VIEWER',
                              'SNOWFLAKE.OBJECT_VIEWER', 'SNOWFLAKE.ORGANIZATION_BILLING_VIEWER',
                              'SNOWFLAKE.ORGANIZATION_USAGE_VIEWER', 'SNOWFLAKE.ORGANIZATION_ACCOUNTS_VIEWER')))
  GROUP BY grantee_name
),
reach AS (
  SELECT ur.role_name, ur.user_name, MIN(ur.depth) AS depth
  FROM sf_sec_user_roles ur
  JOIN holds h ON h.role_name = ur.role_name
  JOIN sf_sec_users u ON u.user_name = ur.user_name AND NOT u.is_disabled
  GROUP BY ur.role_name, ur.user_name
),
counts AS (
  SELECT role_name, COUNT_IF(depth = 0) AS direct_users, COUNT(*) AS total_users,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(user_name) WITHIN GROUP (ORDER BY user_name), 0, 10), ', ') AS users
  FROM reach
  GROUP BY role_name
),
j AS (
  SELECT h.role_name, h.holds_imported_privileges, h.database_roles, h.created_on, h.granted_by,
         IFF(h.role_name = 'PUBLIC', (SELECT COUNT(*) FROM sf_sec_users WHERE NOT is_disabled), COALESCE(c.direct_users, 0)) AS direct_users,
         IFF(h.role_name = 'PUBLIC', (SELECT COUNT(*) FROM sf_sec_users WHERE NOT is_disabled), COALESCE(c.total_users, 0)) AS total_users,
         c.users
  FROM holds h
  LEFT JOIN counts c ON c.role_name = h.role_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, role_name, holds_imported_privileges, database_roles,
       direct_users, total_users, users, granted_by, created_on,
       CASE
         WHEN role_name = 'ACCOUNTADMIN' THEN 'default for ACCOUNTADMIN'
         WHEN role_name = 'PUBLIC' THEN 'every user can read the usage views'
         WHEN total_users >= :warn_users THEN total_users || ' users can read the usage views'
       END AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN role_name = 'ACCOUNTADMIN' THEN 'OK'
         WHEN role_name = 'PUBLIC' OR total_users >= :critical_users THEN 'CRITICAL'
         WHEN total_users >= :warn_users THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, total_users DESC, role_name
