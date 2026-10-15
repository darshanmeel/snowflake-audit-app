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
