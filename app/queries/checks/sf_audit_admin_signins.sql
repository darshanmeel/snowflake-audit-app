-- query_id: sf_audit_admin_signins
-- title: How users who can use an admin role signed in
-- domain: governance_access   tier: standard
-- entity: admin users = user_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_ips (default 5) source IPs: an admin user who signed in from this many IPs reads WARN;
--   :night_start_hour (default 22) UTC hour: sign-ins from this hour on count as night; :night_end_hour
--   (default 6) UTC hour: sign-ins before this hour count as night; :warn_night_pct (default 50) night
--   pct: at or above this share of an admin user's sign-ins the row reads WARN; :crit_failures (default
--   20) failed sign-ins: an admin user with a password-only sign-in and this many failures reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user who can use an admin role and signed in during the window. Admin roles are
--   ACCOUNTADMIN, SECURITYADMIN, USERADMIN and ORGADMIN (as in sf_sec_admin_role_holders), reached directly or through role
--   grants. logins and failures count
--   successful and failed sign-ins; ips and client_types count where they came from and what they used;
--   password_only_logins counts successful sign-ins with a password and no second factor; night_logins
--   counts sign-ins between night_start_hour and night_end_hour UTC. It is the record of how the admin
--   accounts were used, next to the state checks (sf_sec_users_without_mfa, sf_sec_new_login_sources).
-- healthy: status = OK when an admin user signed in with a second factor from a few IPs in working hours.
-- investigate_if: WARN when the user signed in with a password only, from warn_ips or more IPs, or mostly at
--   night (>= warn_night_pct); CRITICAL when a password-only sign-in is combined with failures >=
--   crit_failures (the account is being guessed at).
-- actions: 1) enrol the user in MFA or move a service login to key pair, and set an authentication policy
--   that requires it (config); 2) check the night and many-IP rows with the user (free); 3) give each
--   person a named admin login and keep the shared one for break-glass only (spend).
-- next: sf_sec_users_without_mfa
-- empty_if: role_cannot_see, no_activity
-- caveats: LOGIN_HISTORY lags up to 2 hours; hours are UTC, not the user's time zone. A user with an
--   admin role and no sign-in in the window is not listed (see sf_sec_stale_users). Only events of type
--   LOGIN are counted. Roles reached through a database role are not followed.
WITH __INCLUDE_sf_sec_user_roles__,
admin AS (
  SELECT user_name, ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT role_name), 0, 5), ', ') AS admin_roles
  FROM sf_sec_user_roles
  -- the same admin roles as sf_sec_admin_role_holders, so the pages count one admin population
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN')
  GROUP BY user_name
),
l AS (
  SELECT user_name,
         COUNT_IF(is_success = 'YES') AS logins,
         COUNT_IF(is_success = 'NO') AS failures,
         COUNT(DISTINCT IFF(is_success = 'YES', client_ip, NULL)) AS ips,
         COUNT(DISTINCT IFF(is_success = 'YES', reported_client_type, NULL)) AS client_types,
         COUNT_IF(is_success = 'YES' AND first_authentication_factor = 'PASSWORD'
                  AND second_authentication_factor IS NULL) AS password_only_logins,
         COUNT_IF(is_success = 'YES' AND (HOUR(event_timestamp) >= :night_start_hour
                                          OR HOUR(event_timestamp) < :night_end_hour)) AS night_logins,
         MAX(IFF(is_success = 'YES', event_timestamp, NULL)) AS last_login
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
    AND event_type = 'LOGIN'
  GROUP BY user_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, a.user_name, a.admin_roles, l.logins,
       l.failures, l.ips, l.client_types, l.password_only_logins, l.night_logins,
       ROUND(100 * l.night_logins / NULLIF(l.logins, 0), 1) AS night_pct, l.last_login,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(l.password_only_logins > 0, l.password_only_logins || ' sign-ins with a password only', NULL),
         IFF(l.ips >= :warn_ips, l.ips || ' source IPs', NULL),
         IFF(100 * l.night_logins / NULLIF(l.logins, 0) >= :warn_night_pct, 'mostly at night (UTC)', NULL),
         IFF(l.failures >= :crit_failures, l.failures || ' failed sign-ins', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN l.password_only_logins > 0 AND l.failures >= :crit_failures THEN 'CRITICAL'
         WHEN l.password_only_logins > 0 OR l.ips >= :warn_ips
           OR 100 * l.night_logins / NULLIF(l.logins, 0) >= :warn_night_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM admin a
JOIN l ON l.user_name = a.user_name
WHERE l.logins > 0
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, l.logins DESC, a.user_name
