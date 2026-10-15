-- query_id: sf_audit_admin_sessions
-- title: Sessions of admin-capable users, by how they signed in and how long they stay open
-- domain: governance_access   tier: standard
-- entity: admin users = user_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_open_hours (default 24) open hours: a session still open after this long reads WARN;
--   :crit_open_hours (default 168) open hours: a session still open after this long reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one admin-capable user x authentication method with sessions created in the window.
--   Admin roles are ACCOUNTADMIN, SECURITYADMIN, USERADMIN and ORGADMIN (as in sf_sec_admin_role_holders), and the method is
--   password, key pair, SSO, OAuth and so on. sessions counts them, open_sessions those still open and longest_open_hours the oldest of those, in
--   hours since creation. forced_logouts and abandoned count sessions Snowflake ended (FORCED_LOGOUT) or
--   that timed out unused (ABANDONED). client_apps names up to five clients used.
-- healthy: status = OK when admin sessions close soon after they open.
-- investigate_if: WARN when a session is still open after warn_open_hours; CRITICAL after
--   crit_open_hours (a keep-alive or a stolen token can hold an admin session open for days).
-- actions: 1) ask the user to sign out of the client that holds the session, and rotate the credential
--   if the client is not one you know (free); 2) set a session policy with a short idle
--   timeout for admin roles (config); 3) stop using an admin role for automation and move it to a
--   least-privilege service user (spend).
-- next: sf_audit_admin_signins
-- empty_if: role_cannot_see, no_activity
-- caveats: SESSIONS omits SQL API transient sessions and system sessions and lags up to 3 hours, so a
--   session's age is measured to the as-of date (the same cut-off as every other check), and a session
--   opened today is left out. IS_OPEN is a point-in-time flag: a session that closed since is not listed
--   as open. The AUTHENTICATION_METHOD text is shown as
--   Snowflake reports it.
WITH __INCLUDE_sf_sec_user_roles__,
admin AS (
  SELECT user_name
  FROM sf_sec_user_roles
  -- the same admin roles as sf_sec_admin_role_holders, so the pages count one admin population
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN')
  GROUP BY user_name
),
s AS (
  SELECT s.user_name, COALESCE(s.authentication_method, '(unknown)') AS authentication_method,
         COUNT(*) AS sessions,
         COUNT_IF(UPPER(TO_VARCHAR(s.is_open)) IN ('YES', 'TRUE')) AS open_sessions,
         MAX(IFF(UPPER(TO_VARCHAR(s.is_open)) IN ('YES', 'TRUE'),
                 DATEDIFF(hour, s.created_on, __AS_OF_DATE__), NULL)) AS longest_open_hours,
         COUNT_IF(s.closed_reason = 'FORCED_LOGOUT') AS forced_logouts,
         COUNT_IF(s.closed_reason = 'ABANDONED') AS abandoned,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT SPLIT_PART(s.client_application_id, ' ', 1)), 0, 5), ', ') AS client_apps,
         MAX(s.created_on) AS last_session
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS s
  JOIN admin a ON a.user_name = s.user_name
  WHERE s.created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND s.created_on < __AS_OF_DATE__
  GROUP BY s.user_name, COALESCE(s.authentication_method, '(unknown)')
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, authentication_method, sessions,
       open_sessions, longest_open_hours, forced_logouts, abandoned, client_apps, last_session,
       CASE WHEN longest_open_hours >= :warn_open_hours
            THEN open_sessions || ' session(s) still open, the oldest for ' || longest_open_hours || ' hours' END AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN longest_open_hours >= :crit_open_hours THEN 'CRITICAL'
         WHEN longest_open_hours >= :warn_open_hours THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, longest_open_hours DESC NULLS LAST, user_name
