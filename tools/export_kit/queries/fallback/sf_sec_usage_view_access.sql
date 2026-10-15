-- query_id: sf_sec_usage_view_access
-- shims: USERS, ROLES, GRANTS_TO_ROLES, GRANTS_TO_USERS
-- reads: INFORMATION_SCHEMA table functions SHOW USERS, SHOW ROLES, SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role), SHOW GRANTS OF ROLE (per role)
-- fallback_note: live users only; no password-change dates; the name stands in for the user id; account roles only (no database or instance roles); the name stands in for the role id; current grants to account and database roles; no inherited or future grants; current role grants to users
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
  FROM __SHIM_USERS__
  -- Snowflake-managed users (SNOWFLAKE, WORKSHEETS_APP_USER) are not the customer's to change.
  WHERE deleted_on IS NULL AND COALESCE(UPPER(type), '') <> 'SNOWFLAKE_SERVICE'
    AND UPPER(name) NOT IN ('SNOWFLAKE', 'WORKSHEETS_APP_USER')
),
-- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
-- every role a user can use through a direct grant. A child role is NAME, its parent GRANTEE_NAME.
sf_sec_role_reach AS (
  SELECT name AS top_role, name AS role_name, 0 AS depth, CAST(name AS VARCHAR) AS path
  FROM __SHIM_ROLES__
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT r.top_role, g.name, r.depth + 1, r.path || ' > ' || g.name
  FROM sf_sec_role_reach r
  JOIN __SHIM_GRANTS_TO_ROLES__ g
    ON g.grantee_name = r.role_name AND g.granted_on = 'ROLE' AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
   AND g.privilege = 'USAGE' AND g.deleted_on IS NULL
  -- Snowflake forbids cycles; the cap only guards against a malformed history.
  WHERE r.depth < 20
),
sf_sec_user_roles AS (
  SELECT gu.grantee_name AS user_name, gu.role AS granted_role, r.role_name, r.depth, r.path
  FROM __SHIM_GRANTS_TO_USERS__ gu
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
  FROM __SHIM_GRANTS_TO_ROLES__
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
