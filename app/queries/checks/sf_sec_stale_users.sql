-- query_id: sf_sec_stale_users
-- title: Enabled users that no longer sign in
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :stale_days (default 90) stale days: value this check uses; :crit_stale_days (default 180)
--   stale days: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one enabled user with no successful sign-in for :stale_days days, or never
--   signed in and created over :stale_days days ago. days_since_login is NULL for never. admin_roles
--   lists admin roles the user can reach; has_password shows whether a credential that could be guessed
--   is still there.
-- healthy: status = OK never appears; no rows means every enabled user signed in recently.
-- investigate_if: WARN for every stale user; CRITICAL when the user is idle :crit_stale_days+ days (or
--   never signed in) and still has a password, or can use an admin role.
-- actions: 1) confirm with the owner, then ALTER USER ... SET DISABLED = TRUE (free); 2) drop the user
--   after a quarter disabled, transferring anything it owns first (free); 3) feed leavers from the IdP
--   via SCIM so users are disabled automatically (config)
-- next: none
-- caveats: LAST_SUCCESS_LOGIN covers every sign-in method, including key-pair and OAuth; a user only
--   used through EXECUTE AS OWNER objects or tasks never signs in and will show here. Lags up to 2
--   hours.
WITH __INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
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
