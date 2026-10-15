-- query_id: sf_sec_password_service_users
-- shims: USERS, LOGIN_HISTORY
-- reads: INFORMATION_SCHEMA table functions SHOW USERS, LOGIN_HISTORY
-- fallback_note: live users only; no password-change dates; the name stands in for the user id; sign-ins for the last 7 days at most, only the users this role can monitor, up to 10,000 a day
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
logins AS (
  SELECT user_name,
         COUNT(*) AS successful_logins,
         COUNT_IF(first_authentication_factor = 'PASSWORD') AS password_logins,
         COUNT_IF(first_authentication_factor = 'RSA_KEYPAIR') AS keypair_logins,
         COUNT_IF(reported_client_type = 'SNOWFLAKE_UI') AS ui_logins,
         LISTAGG(DISTINCT reported_client_type, ', ') WITHIN GROUP (ORDER BY reported_client_type) AS client_types,
         LISTAGG(DISTINCT first_authentication_factor, ', ')
           WITHIN GROUP (ORDER BY first_authentication_factor) AS auth_methods,
         COUNT(DISTINCT client_ip) AS distinct_ips,
         MAX(event_timestamp) AS last_login
  FROM __SHIM_LOGIN_HISTORY__
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
    AND is_success = 'YES'
  GROUP BY user_name
),
c AS (
  SELECT u.*, COALESCE(l.successful_logins, 0) AS successful_logins,
         COALESCE(l.password_logins, 0) AS password_logins, COALESCE(l.keypair_logins, 0) AS keypair_logins,
         l.client_types, l.auth_methods, COALESCE(l.distinct_ips, 0) AS distinct_ips, l.last_login,
         (u.user_type = 'PERSON' AND COALESCE(l.successful_logins, 0) >= :min_driver_logins
          AND COALESCE(l.ui_logins, 0) = 0) AS looks_like_program
  FROM sf_sec_users u
  LEFT JOIN logins l ON l.user_name = u.user_name
  WHERE NOT u.is_disabled
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, email, user_type,
       looks_like_program, has_password, has_rsa_key, default_role, owner AS owner_role,
       successful_logins, password_logins, keypair_logins, auth_methods, client_types, distinct_ips,
       last_login, password_last_set_time,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(user_type <> 'PERSON' AND password_logins > 0, password_logins || ' password sign-ins', NULL),
         IFF(user_type = 'LEGACY_SERVICE' AND has_password, 'LEGACY_SERVICE with a password', NULL),
         IFF(looks_like_program, 'PERSON-typed user with only driver sign-ins', NULL),
         IFF(looks_like_program AND password_logins > 0, 'program signing in with a password', NULL),
         IFF(user_type <> 'PERSON' AND NOT has_rsa_key, 'no RSA key registered', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN user_type IN ('SERVICE', 'LEGACY_SERVICE') AND password_logins > 0 THEN 'CRITICAL'
         WHEN user_type = 'LEGACY_SERVICE' AND has_password THEN 'WARN'
         WHEN looks_like_program AND (password_logins > 0 OR has_password) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM c
WHERE user_type IN ('SERVICE', 'LEGACY_SERVICE') OR looks_like_program
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, password_logins DESC
