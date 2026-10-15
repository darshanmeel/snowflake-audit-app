-- query_id: sf_secx_user_auth_state
-- title: Users with MFA bypass active, locked, or past expiry but still enabled
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- empty_if: role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. SNOWFLAKE_LOCK is VARIANT and read as a boolean.
-- read_this: one row = one enabled user. mfa_bypass_active is TRUE while BYPASS_MFA_UNTIL is in the
--   future (mfa_bypass_until says when it ends); is_locked is TRUE when Snowflake's lock is set or
--   LOCKED_UNTIL_TIME is in the future; expired_but_enabled is TRUE when EXPIRES_AT has passed but the
--   user is not disabled. admin_roles lists admin roles the user can use. Times are compared with the
--   export date.
-- healthy: status = OK when none of the three states applies.
-- investigate_if: WARN when MFA is bypassed, the user is locked, or the user is expired but still
--   enabled; CRITICAL when an admin user has an active MFA bypass.
-- actions: 1) clear the bypass with ALTER USER ... UNSET MINS_TO_BYPASS_MFA once the reason is gone
--   (free); 2) disable or drop users past their expiry (free); 3) look into locked users for failed
--   sign-in bursts (free)
-- next: sf_sec_users_without_mfa
-- caveats: USERS lags up to 2 hours. Comparisons use the export date at 00:00 UTC, not the time of the
--   run, so a bypass ending today still reads active.
WITH -- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
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
