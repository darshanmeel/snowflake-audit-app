-- query_id: sf_sec_password_service_users
-- title: Programs signing in with a password
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_driver_logins (default 20) driver logins: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one enabled user that is a program: TYPE = SERVICE or LEGACY_SERVICE, or a
--   PERSON user whose successful sign-ins in the window all came from drivers/connectors (not the web
--   UI, at least :min_driver_logins of them). password_logins counts sign-ins whose first factor was
--   PASSWORD.
-- healthy: status = OK when the program authenticates with key-pair, OAuth, workload identity or a
--   programmatic token and has no password.
-- investigate_if: WARN when a LEGACY_SERVICE user still has a password, or a PERSON-typed program signs
--   in with a password; CRITICAL when a SERVICE / LEGACY_SERVICE user actually signed in with a
--   password in the window.
-- actions: 1) register a key pair (ALTER USER ... SET RSA_PUBLIC_KEY), switch the client, then UNSET
--   PASSWORD (free); 2) ALTER USER ... SET TYPE = SERVICE so passwords and interactive sign-in are
--   refused (config); 3) pin the program to a network policy with only its egress IPs (config)
-- next: none
-- caveats: the PERSON-typed program guess uses REPORTED_CLIENT_TYPE, which the client reports itself;
--   ACCOUNT_USAGE lags up to 2 hours.
WITH __INCLUDE_sf_sec_users__,
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
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
