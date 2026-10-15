-- query_id: sf_sec_users_without_mfa
-- title: Person users signing in with a password and no MFA
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_password_logins (default 1) password logins: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one enabled PERSON user that has a password and no MFA enrolled (HAS_MFA and Duo
--   both false). password_only_logins counts successful sign-ins in the window whose first factor was
--   PASSWORD with no second factor; admin_roles lists ACCOUNTADMIN / SECURITYADMIN / ORGADMIN /
--   USERADMIN / SYSADMIN reachable from the user's grants.
-- healthy: status = OK when the user has a password but did not sign in with it alone in the window
--   (e.g. they use SSO); no rows at all is best.
-- investigate_if: WARN when the user signed in :warn_password_logins+ times with only a password;
--   CRITICAL when that user can also use an admin role.
-- actions: 1) enrol the user in MFA or move them to SSO and UNSET PASSWORD (free); 2) attach an
--   authentication policy with MFA_ENROLLMENT = REQUIRED to the account or the users (config); 3) if
--   the user is really a program, ALTER USER ... SET TYPE = SERVICE and use key-pair auth (config)
-- next: none
-- caveats: ACCOUNT_USAGE lags up to 2 hours; HAS_MFA reflects Snowflake-native MFA and Duo only, so MFA
--   enforced by an external IdP (SAML/OAuth) is not visible here, which is why only password sign-ins
--   count.
WITH __INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
admin AS (
  SELECT user_name, LISTAGG(DISTINCT role_name, ', ') WITHIN GROUP (ORDER BY role_name) AS admin_roles
  FROM sf_sec_user_roles
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN', 'SYSADMIN')
  GROUP BY user_name
),
logins AS (
  SELECT user_name,
         COUNT_IF(is_success = 'YES') AS successful_logins,
         COUNT_IF(is_success = 'YES' AND first_authentication_factor = 'PASSWORD'
                  AND second_authentication_factor IS NULL) AS password_only_logins,
         COUNT(DISTINCT IFF(is_success = 'YES', client_ip, NULL)) AS distinct_ips,
         MAX(IFF(is_success = 'YES', event_timestamp, NULL)) AS last_login
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
  GROUP BY user_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, u.user_id, u.user_name, u.email,
       u.user_type, u.default_role, a.admin_roles, u.has_password, u.has_mfa, u.has_duo, u.has_rsa_key,
       u.password_last_set_time, u.last_success_login,
       COALESCE(l.successful_logins, 0) AS successful_logins,
       COALESCE(l.password_only_logins, 0) AS password_only_logins,
       COALESCE(l.distinct_ips, 0) AS distinct_ips,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(COALESCE(l.password_only_logins, 0) > 0,
             l.password_only_logins || ' password-only sign-ins in the window', NULL),
         IFF(a.admin_roles IS NOT NULL, 'can use ' || a.admin_roles, NULL),
         IFF(COALESCE(l.password_only_logins, 0) = 0, 'has a password it did not use alone', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN COALESCE(l.password_only_logins, 0) >= :warn_password_logins AND a.admin_roles IS NOT NULL THEN 'CRITICAL'
         WHEN COALESCE(l.password_only_logins, 0) >= :warn_password_logins THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM sf_sec_users u
LEFT JOIN logins l ON l.user_name = u.user_name
LEFT JOIN admin a ON a.user_name = u.user_name
WHERE u.user_type = 'PERSON' AND NOT u.is_disabled AND u.has_password AND NOT u.has_mfa AND NOT u.has_duo
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, password_only_logins DESC
