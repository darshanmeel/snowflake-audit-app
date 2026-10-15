-- query_id: sf_sec_admin_role_holders
-- title: Who holds ACCOUNTADMIN, SECURITYADMIN and ORGADMIN
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :max_accountadmins (default 5) accountadmins: limit above which the row flags; :stale_days
--   (default 90) stale days: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live user x admin role (ACCOUNTADMIN, SECURITYADMIN, ORGADMIN, USERADMIN)
--   the user can use, directly or through a custom role (grant_path shows the chain); roles implied by
--   a higher system admin role the user holds are folded into that row. default_role_is_admin is TRUE
--   when the user starts every session in an admin role. accountadmin_holders is the account-wide count
--   of enabled users that can use ACCOUNTADMIN.
-- healthy: status = OK when the holder is an enabled person with MFA (or no password, i.e. SSO), signs
--   in regularly and does not default to the admin role; 2 to :max_accountadmins ACCOUNTADMIN holders.
-- investigate_if: WARN when the default role is an admin role, the holder is idle :stale_days+ days, is
--   a service user, the role comes through a custom role (inherited_depth > 0), or ACCOUNTADMIN holders
--   are under 2 or over :max_accountadmins; CRITICAL when an enabled holder has a password and no MFA.
-- actions: 1) set a non-admin DEFAULT_ROLE and use USE ROLE only when needed (free); 2) revoke admin
--   roles from idle, service and inherited holders; grant them to named people only (free); 3) enforce
--   MFA with an authentication policy on admin users (config)
-- next: none
-- caveats: MFA via an external IdP is not visible, so an SSO user with no password counts as covered;
--   disabled holders are listed as OK for completeness. Lags up to 2 hours.
WITH __INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
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
