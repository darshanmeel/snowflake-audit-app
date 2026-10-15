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
WITH -- Live users with the auth flags normalised: DISABLED and EXT_AUTHN_DUO can come back as VARIANT
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
-- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
-- every role a user can use through a direct grant. A child role is NAME, its parent GRANTEE_NAME.
sf_sec_role_reach AS (
  SELECT name AS top_role, name AS role_name, 0 AS depth, CAST(name AS VARCHAR) AS path
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT r.top_role, g.name, r.depth + 1, r.path || ' > ' || g.name
  FROM sf_sec_role_reach r
  JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
    ON g.grantee_name = r.role_name AND g.granted_on = 'ROLE' AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
   AND g.privilege = 'USAGE' AND g.deleted_on IS NULL
  -- Snowflake forbids cycles; the cap only guards against a malformed history.
  WHERE r.depth < 20
),
sf_sec_user_roles AS (
  SELECT gu.grantee_name AS user_name, gu.role AS granted_role, r.role_name, r.depth, r.path
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu
  JOIN sf_sec_role_reach r ON r.top_role = gu.role
  WHERE gu.deleted_on IS NULL
),
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
