-- query_id: sf_sec_users_without_mfa
-- shims: USERS, ROLES, GRANTS_TO_ROLES, GRANTS_TO_USERS, LOGIN_HISTORY
-- reads: INFORMATION_SCHEMA table functions SHOW USERS, SHOW ROLES, SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role), SHOW GRANTS OF ROLE (per role), LOGIN_HISTORY
-- fallback_note: live users only; no password-change dates; the name stands in for the user id; account roles only (no database or instance roles); the name stands in for the role id; current grants to account and database roles; no inherited or future grants; current role grants to users; sign-ins for the last 7 days at most, only the users this role can monitor, up to 10,000 a day
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
logins AS (
  SELECT user_name,
         COUNT_IF(is_success = 'YES') AS successful_logins,
         COUNT_IF(is_success = 'YES' AND first_authentication_factor = 'PASSWORD'
                  AND second_authentication_factor IS NULL) AS password_only_logins,
         COUNT(DISTINCT IFF(is_success = 'YES', client_ip, NULL)) AS distinct_ips,
         MAX(IFF(is_success = 'YES', event_timestamp, NULL)) AS last_login
  FROM __SHIM_LOGIN_HISTORY__
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
