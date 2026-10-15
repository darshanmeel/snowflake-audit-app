-- query_id: sf_secx_key_and_password_age
-- title: Old passwords still used to sign in, and key pairs whose age is unknown
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :max_password_days (default 180) password days: limit above which the row flags
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one enabled user with a password or an RSA key. password_age_days counts from
--   PASSWORD_LAST_SET_TIME (or the user's creation when it was never reset); password_logins counts
--   successful sign-ins in the window whose first factor was PASSWORD, key_logins those with
--   RSA_KEYPAIR.
-- healthy: status = OK when the password was set in the last :max_password_days days, or it is not used
--   and the user signs in some other way.
-- investigate_if: WARN when a password older than :max_password_days days is still used to sign in, or
--   an old password is kept although nobody signs in with it; CRITICAL when that old, used password
--   belongs to a user who can use an admin role. NOT_ASSESSED for key-pair-only users: their key age is
--   read by sf_secx_key_pair_age.
-- actions: 1) rotate the old passwords, or UNSET PASSWORD where the user signs in with SSO or a key
--   (free); 2) attach a password policy with PASSWORD_MAX_AGE_DAYS to the account (config); its attachment is not
--   listed in POLICY_REFERENCES, so this check does not read it; 3) for
--   key-pair users see sf_secx_key_pair_age and rotate through RSA_PUBLIC_KEY_2 (free)
-- next: none
-- caveats: ACCOUNT_USAGE lags up to 2 hours; USERS does not expose when an RSA key was set; key age
--   comes from CREDENTIALS in sf_secx_key_pair_age.
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
         COUNT_IF(first_authentication_factor = 'PASSWORD') AS password_logins,
         COUNT_IF(first_authentication_factor = 'RSA_KEYPAIR') AS key_logins,
         COUNT(*) AS successful_logins,
         MAX(IFF(first_authentication_factor = 'PASSWORD', event_timestamp, NULL)) AS last_password_login
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
    AND is_success = 'YES'
  GROUP BY user_name
),
j AS (
  SELECT u.user_id, u.user_name, u.user_type, u.default_role, a.admin_roles, u.has_password, u.has_rsa_key,
         u.has_mfa, u.password_last_set_time, u.created_on,
         IFF(u.has_password, DATEDIFF(day, COALESCE(u.password_last_set_time, u.created_on), __AS_OF_DATE__), NULL) AS password_age_days,
         COALESCE(l.password_logins, 0) AS password_logins, COALESCE(l.key_logins, 0) AS key_logins,
         COALESCE(l.successful_logins, 0) AS successful_logins, l.last_password_login
  FROM sf_sec_users u
  LEFT JOIN admin a ON a.user_name = u.user_name
  LEFT JOIN logins l ON l.user_name = u.user_name
  WHERE NOT u.is_disabled AND (u.has_password OR u.has_rsa_key)
),
s AS (
  SELECT j.*,
         (has_password AND password_age_days > :max_password_days) AS password_old,
         CASE
           WHEN has_password AND password_age_days > :max_password_days AND password_logins > 0
                AND admin_roles IS NOT NULL THEN 'CRITICAL'
           WHEN has_password AND password_age_days > :max_password_days THEN 'WARN'
           WHEN NOT has_password AND has_rsa_key THEN 'NOT_ASSESSED'
           ELSE 'OK'
         END AS status
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, user_type, default_role,
       admin_roles, has_password, has_rsa_key, has_mfa, password_last_set_time, password_age_days,
       successful_logins, password_logins, key_logins, last_password_login,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(password_old, 'password is ' || password_age_days || ' days old', NULL),
         IFF(password_old AND password_logins > 0, password_logins || ' password sign-ins in the window', NULL),
         IFF(password_old AND password_logins = 0, 'password kept but not used to sign in', NULL),
         IFF(admin_roles IS NOT NULL, 'can use ' || admin_roles, NULL),
         IFF(has_rsa_key, 'has an RSA key; its age needs DESCRIBE USER', NULL)), '; ') AS reasons,
       IFF(status = 'NOT_ASSESSED', 'key-pair user with no password: RSA key age is in sf_secx_key_pair_age',
           NULL) AS not_assessed_reason,
       status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END,
         password_logins DESC, password_age_days DESC NULLS LAST
