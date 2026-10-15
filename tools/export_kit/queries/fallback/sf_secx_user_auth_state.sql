-- query_id: sf_secx_user_auth_state
-- shims: ROLES, GRANTS_TO_ROLES, GRANTS_TO_USERS, USERS
-- reads: INFORMATION_SCHEMA table functions SHOW ROLES, SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role), SHOW GRANTS OF ROLE (per role), SHOW USERS
-- fallback_note: account roles only (no database or instance roles); the name stands in for the role id; current grants to account and database roles; no inherited or future grants; current role grants to users; live users only; no password-change dates; the name stands in for the user id
WITH -- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
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
u AS (
  SELECT TO_VARCHAR(user_id) AS user_id, name AS user_name, COALESCE(UPPER(type), 'PERSON') AS user_type,
         COALESCE(has_mfa, FALSE) AS has_mfa, bypass_mfa_until, locked_until_time, expires_at, last_success_login,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(snowflake_lock)), FALSE) AS snowflake_locked
  FROM __SHIM_USERS__
  WHERE deleted_on IS NULL AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)
),
s AS (
  SELECT u.*, a.admin_roles,
         COALESCE(u.bypass_mfa_until > __AS_OF_DATE__, FALSE) AS mfa_bypass_active,
         (u.snowflake_locked OR COALESCE(u.locked_until_time > __AS_OF_DATE__, FALSE)) AS is_locked,
         COALESCE(u.expires_at < __AS_OF_DATE__, FALSE) AS expired_but_enabled
  FROM u
  LEFT JOIN admin a ON a.user_name = u.user_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, user_type, admin_roles, has_mfa,
       mfa_bypass_active, bypass_mfa_until AS mfa_bypass_until, is_locked, locked_until_time, expired_but_enabled,
       expires_at, last_success_login,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(mfa_bypass_active, 'MFA bypassed until ' || TO_VARCHAR(bypass_mfa_until, 'YYYY-MM-DD HH24:MI'), NULL),
         IFF(is_locked, 'user is locked', NULL),
         IFF(expired_but_enabled, 'expired ' || TO_VARCHAR(expires_at, 'YYYY-MM-DD') || ' but not disabled', NULL),
         IFF(expired_but_enabled AND last_success_login > expires_at, 'signed in after expiry', NULL),
         IFF(admin_roles IS NOT NULL AND (mfa_bypass_active OR is_locked OR expired_but_enabled),
             'can use ' || admin_roles, NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN mfa_bypass_active AND admin_roles IS NOT NULL THEN 'CRITICAL'
         WHEN mfa_bypass_active OR is_locked OR expired_but_enabled THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, user_name
