-- query_id: sf_sec_admin_role_holders
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
held AS (
  SELECT user_name, role_name AS admin_role, MIN(depth) AS depth,
         MIN_BY(path, depth) AS grant_path, MIN_BY(granted_role, depth) AS granted_role
  FROM sf_sec_user_roles
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN')
  GROUP BY user_name, role_name
  -- A role implied by a higher system admin role (ACCOUNTADMIN > SECURITYADMIN > USERADMIN) is not a new fact.
  HAVING NOT (MIN(depth) > 0 AND MIN_BY(granted_role, depth) IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN'))
),
j AS (
  SELECT h.*, u.user_id, u.email, u.user_type, u.is_disabled, u.has_password, u.has_mfa, u.has_duo, u.has_rsa_key,
         u.default_role, u.default_secondary_role, u.last_success_login,
         DATEDIFF(day, u.last_success_login, __AS_OF_DATE__) AS days_since_login,
         u.default_role IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN') AS default_role_is_admin,
         (u.has_password AND NOT u.has_mfa AND NOT u.has_duo) AS password_without_mfa,
         COUNT(DISTINCT IFF(h.admin_role = 'ACCOUNTADMIN' AND NOT u.is_disabled, h.user_name, NULL)) OVER () AS accountadmin_holders
  FROM held h
  JOIN sf_sec_users u ON u.user_name = h.user_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, email, user_type, admin_role,
       granted_role, depth AS inherited_depth, grant_path, is_disabled, default_role, default_role_is_admin,
       default_secondary_role, has_password, has_mfa, has_duo, has_rsa_key, password_without_mfa,
       last_success_login, days_since_login, accountadmin_holders,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(password_without_mfa, 'password without MFA', NULL),
         IFF(default_role_is_admin, 'default role is ' || default_role, NULL),
         IFF(COALESCE(days_since_login, 99999) >= :stale_days, 'no sign-in for ' || COALESCE(TO_VARCHAR(days_since_login), 'ever'), NULL),
         IFF(user_type <> 'PERSON', user_type || ' user holds an admin role', NULL),
         IFF(depth > 0, 'inherited via ' || grant_path, NULL),
         IFF(admin_role = 'ACCOUNTADMIN' AND accountadmin_holders < 2, 'only one ACCOUNTADMIN holder', NULL),
         IFF(admin_role = 'ACCOUNTADMIN' AND accountadmin_holders > :max_accountadmins,
             accountadmin_holders || ' ACCOUNTADMIN holders', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN is_disabled THEN 'OK'
         WHEN password_without_mfa THEN 'CRITICAL'
         WHEN default_role_is_admin OR COALESCE(days_since_login, 99999) >= :stale_days OR user_type <> 'PERSON'
              OR depth > 0
              OR (admin_role = 'ACCOUNTADMIN' AND (accountadmin_holders < 2 OR accountadmin_holders > :max_accountadmins))
           THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, admin_role, user_name
