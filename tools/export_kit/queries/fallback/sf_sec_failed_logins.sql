-- query_id: sf_sec_failed_logins
-- shims: LOGIN_HISTORY, USERS
-- reads: INFORMATION_SCHEMA table functions LOGIN_HISTORY, SHOW USERS
-- fallback_note: sign-ins for the last 7 days at most, only the users this role can monitor, up to 10,000 a day; live users only; no password-change dates; the name stands in for the user id
WITH f AS (
  -- a failure with no user name is kept: the NULL would drop it from every join below
  SELECT COALESCE(UPPER(user_name), '(no user name)') AS user_name, COALESCE(client_ip, '(no ip)') AS client_ip, reported_client_type, is_success, error_code, error_message,
         first_authentication_factor, event_timestamp,
         -- short cause label from Snowflake's fixed error code and message, for a by-cause bar
         CASE
           WHEN is_success <> 'NO' THEN NULL
           WHEN error_code = 390422 OR error_message ILIKE '%IP_BLOCKED%' OR error_message ILIKE '%NETWORK_POLICY%' THEN 'network policy'
           WHEN error_code BETWEEN 390120 AND 390132 OR error_message ILIKE '%MFA%' OR error_message ILIKE '%EXT_AUTHN%'
                OR error_message ILIKE '%TOTP%' THEN 'MFA'
           -- LOCK but not BLOCK: an IP blocked by a network policy is not a locked user
           WHEN (error_message ILIKE '%LOCK%' AND error_message NOT ILIKE '%BLOCK%') OR error_message ILIKE '%DISABLED%' THEN 'user locked or disabled'
           WHEN error_message ILIKE '%SAML%' OR error_message ILIKE '%OIDC%' OR error_message ILIKE 'FED%' THEN 'SSO'
           WHEN error_message ILIKE '%JWT%' OR error_message ILIKE '%TOKEN%' OR error_message ILIKE '%OAUTH%' THEN 'key or token'
           -- federated, SAML and OIDC codes from the docs, for rows with no message
           WHEN error_code BETWEEN 390133 AND 390140 OR error_code BETWEEN 390165 AND 390184 OR error_code = 390191
                OR error_code BETWEEN 390250 AND 390264 OR error_code = 390322 THEN 'SSO'
           WHEN error_code = 390100 OR error_message ILIKE '%PASSWORD%' THEN 'password'
           ELSE 'other'
         END AS cause
  FROM __SHIM_LOGIN_HISTORY__
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
),
by_pair AS (
  SELECT user_name, client_ip,
         COUNT_IF(is_success = 'NO') AS failed_logins,
         COUNT_IF(is_success = 'YES') AS successful_logins,
         MIN(IFF(is_success = 'NO', event_timestamp, NULL)) AS first_failure,
         MAX(IFF(is_success = 'NO', event_timestamp, NULL)) AS last_failure,
         MAX(IFF(is_success = 'YES', event_timestamp, NULL)) AS last_success,
         COUNT_IF(is_success = 'NO' AND error_message ILIKE '%lock%' AND error_message NOT ILIKE '%block%') AS lock_errors,
         LISTAGG(DISTINCT IFF(is_success = 'NO', TO_VARCHAR(error_code), NULL), ', ') AS error_codes,
         MAX(IFF(is_success = 'NO', error_message, NULL)) AS sample_error,
         LISTAGG(DISTINCT reported_client_type, ', ') AS client_types,
         LISTAGG(DISTINCT first_authentication_factor, ', ') AS auth_methods,
         MODE(cause) AS top_cause,
         COUNT_IF(cause = 'network policy') AS fails_network_policy,
         COUNT_IF(cause = 'password') AS fails_password,
         COUNT_IF(cause = 'MFA') AS fails_mfa,
         COUNT_IF(cause = 'user locked or disabled') AS fails_locked_or_disabled,
         COUNT_IF(cause = 'key or token') AS fails_key_or_token,
         COUNT_IF(cause = 'SSO') AS fails_sso,
         COUNT_IF(cause = 'other') AS fails_other
  FROM f
  GROUP BY user_name, client_ip
  HAVING COUNT_IF(is_success = 'NO') > 0
),
burst AS (
  -- failures in the worst single hour: typos spread over weeks are not a guessing burst
  SELECT user_name, client_ip, MAX(n) AS peak_hour_failures
  FROM (SELECT user_name, client_ip, DATE_TRUNC('hour', event_timestamp) AS h, COUNT(*) AS n
        FROM f WHERE is_success = 'NO' GROUP BY 1, 2, 3)
  GROUP BY 1, 2
),
by_ip AS (
  SELECT client_ip, COUNT(DISTINCT user_name) AS ip_users_failed
  FROM f WHERE is_success = 'NO'
  GROUP BY client_ip
),
known AS (
  SELECT DISTINCT UPPER(name) AS user_name FROM __SHIM_USERS__ WHERE deleted_on IS NULL
  UNION
  SELECT DISTINCT UPPER(login_name) FROM __SHIM_USERS__ WHERE deleted_on IS NULL
),
j AS (
  SELECT p.*, i.ip_users_failed, b.peak_hour_failures, k.user_name IS NULL AS unknown_user, p.lock_errors > 0 AS locked,
         (p.last_success > p.first_failure AND b.peak_hour_failures >= :warn_failures) AS success_after_failures
  FROM by_pair p
  JOIN by_ip i ON i.client_ip = p.client_ip
  JOIN burst b ON b.user_name = p.user_name AND b.client_ip = p.client_ip
  LEFT JOIN known k ON k.user_name = p.user_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, client_ip, failed_logins,
       successful_logins, peak_hour_failures, ip_users_failed, unknown_user, locked, COALESCE(success_after_failures, FALSE) AS success_after_failures,
       error_codes, sample_error, top_cause, fails_network_policy, fails_password, fails_mfa,
       fails_locked_or_disabled, fails_key_or_token, fails_sso, fails_other, client_types, auth_methods, first_failure, last_failure, last_success,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         failed_logins || ' failed sign-ins',
         IFF(success_after_failures, 'then a successful sign-in from the same IP', NULL),
         IFF(ip_users_failed >= :spray_users, 'IP failed for ' || ip_users_failed || ' user names', NULL),
         IFF(unknown_user, 'user name does not exist', NULL),
         IFF(locked, 'user was locked', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN failed_logins >= :crit_failures OR success_after_failures THEN 'CRITICAL'
         WHEN failed_logins >= :warn_failures OR ip_users_failed >= :spray_users OR locked THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, failed_logins DESC
