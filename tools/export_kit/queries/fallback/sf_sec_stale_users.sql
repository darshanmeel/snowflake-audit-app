-- query_id: sf_sec_stale_users
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
admin AS (
  SELECT user_name, LISTAGG(DISTINCT role_name, ', ') WITHIN GROUP (ORDER BY role_name) AS admin_roles
  FROM sf_sec_user_roles
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN', 'SYSADMIN')
  GROUP BY user_name
),
s AS (
  SELECT u.*, a.admin_roles,
         DATEDIFF(day, u.last_success_login, __AS_OF_DATE__) AS days_since_login,
         DATEDIFF(day, u.created_on, __AS_OF_DATE__) AS days_since_created
  FROM sf_sec_users u
  LEFT JOIN admin a ON a.user_name = u.user_name
  WHERE NOT u.is_disabled
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, email, user_type, default_role,
       admin_roles, has_password, has_mfa, has_rsa_key, created_on, last_success_login,
       days_since_login, days_since_created, last_success_login IS NULL AS never_logged_in,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(last_success_login IS NULL, 'never signed in, created ' || days_since_created || ' days ago',
             'no sign-in for ' || days_since_login || ' days'),
         IFF(has_password, 'still has a password', NULL),
         IFF(admin_roles IS NOT NULL, 'can use ' || admin_roles, NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN admin_roles IS NOT NULL THEN 'CRITICAL'
         WHEN has_password AND COALESCE(days_since_login, days_since_created) >= :crit_stale_days THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM s
WHERE (last_success_login IS NULL AND days_since_created >= :stale_days)
   OR days_since_login >= :stale_days
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 ELSE 1 END, COALESCE(days_since_login, days_since_created) DESC
