-- query_id: sf_audit_admin_signins
-- shims: ROLES, GRANTS_TO_ROLES, GRANTS_TO_USERS, LOGIN_HISTORY
-- reads: INFORMATION_SCHEMA table functions SHOW ROLES, SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role), SHOW GRANTS OF ROLE (per role), LOGIN_HISTORY
-- fallback_note: account roles only (no database or instance roles); the name stands in for the role id; current grants to account and database roles; no inherited or future grants; current role grants to users; sign-ins for the last 7 days at most, only the users this role can monitor, up to 10,000 a day
WITH -- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
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
  FROM __SHIM_LOGIN_HISTORY__
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
