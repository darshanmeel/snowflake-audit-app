-- query_id: sf_sec_new_login_sources
-- title: Sign-ins from IPs and clients not seen before
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :baseline_days (default 90) baseline days: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user x client IP with a successful sign-in in the window and none from that
--   IP in the :baseline_days days before it. new_client_types lists client types the user had not used
--   in the baseline either; baseline_ips is how many IPs the user used before (0 = new or dormant
--   user).
-- healthy: status = OK when the new source belongs to an ordinary user (travel, new laptop, VPN
--   change).
-- investigate_if: WARN when the user can use an admin role or is a SERVICE / LEGACY_SERVICE user
--   (programs should have stable egress IPs); CRITICAL when that admin sign-in from a new IP used a
--   password alone.
-- actions: 1) confirm the sign-in with the user; if unknown, disable the user and rotate credentials
--   (free); 2) put admin and service users behind a user-level network policy (config)
-- next: none
-- caveats: users with no baseline sign-ins are NOT_ASSESSED; dynamic cloud egress IPs make programs
--   look new. LOGIN_HISTORY keeps 365 days and lags up to 2 hours.
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
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN')
  GROUP BY user_name
),
ok AS (
  SELECT user_name, client_ip, reported_client_type, first_authentication_factor, second_authentication_factor,
         event_timestamp,
         event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AS in_window
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -(:period_days + :baseline_days), __AS_OF_DATE__)
    AND event_timestamp < __AS_OF_DATE__ AND is_success = 'YES'
),
base_ip AS (SELECT DISTINCT user_name, client_ip FROM ok WHERE NOT in_window),
base_client AS (SELECT DISTINCT user_name, reported_client_type FROM ok WHERE NOT in_window),
base_n AS (SELECT user_name, COUNT(DISTINCT client_ip) AS baseline_ips FROM ok WHERE NOT in_window GROUP BY user_name),
fresh AS (
  SELECT w.user_name, w.client_ip,
         COUNT(*) AS logins,
         MIN(w.event_timestamp) AS first_seen, MAX(w.event_timestamp) AS last_seen,
         COUNT_IF(w.first_authentication_factor = 'PASSWORD' AND w.second_authentication_factor IS NULL) AS password_only_logins,
         LISTAGG(DISTINCT w.reported_client_type, ', ') AS client_types,
         LISTAGG(DISTINCT IFF(bc.reported_client_type IS NULL, w.reported_client_type, NULL), ', ') AS new_client_types,
         LISTAGG(DISTINCT w.first_authentication_factor, ', ') AS auth_methods
  FROM ok w
  LEFT JOIN base_ip bi ON bi.user_name = w.user_name AND bi.client_ip = w.client_ip
  LEFT JOIN base_client bc ON bc.user_name = w.user_name AND bc.reported_client_type = w.reported_client_type
  WHERE w.in_window AND bi.client_ip IS NULL
  GROUP BY w.user_name, w.client_ip
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, f.user_name, u.email, u.user_type,
       a.admin_roles, f.client_ip, f.logins, f.first_seen, f.last_seen, f.client_types,
       NULLIF(f.new_client_types, '') AS new_client_types, f.auth_methods, f.password_only_logins,
       COALESCE(b.baseline_ips, 0) AS baseline_ips,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         'first sign-in from this IP on ' || TO_VARCHAR(f.first_seen, 'YYYY-MM-DD'),
         IFF(NULLIF(f.new_client_types, '') IS NOT NULL, 'new client ' || f.new_client_types, NULL),
         IFF(a.admin_roles IS NOT NULL, 'can use ' || a.admin_roles, NULL),
         IFF(u.user_type <> 'PERSON', u.user_type || ' user', NULL),
         IFF(f.password_only_logins > 0, 'password-only sign-in', NULL)), '; ') AS reasons,
       CASE WHEN b.baseline_ips IS NULL THEN 'no_baseline_history' END AS not_assessed_reason,
       CASE
         WHEN b.baseline_ips IS NULL THEN 'NOT_ASSESSED'
         WHEN a.admin_roles IS NOT NULL AND f.password_only_logins > 0 THEN 'CRITICAL'
         WHEN a.admin_roles IS NOT NULL OR u.user_type IN ('SERVICE', 'LEGACY_SERVICE') THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM fresh f
LEFT JOIN base_n b ON b.user_name = f.user_name
LEFT JOIN sf_sec_users u ON u.user_name = f.user_name
LEFT JOIN admin a ON a.user_name = f.user_name
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'OK' THEN 2 ELSE 3 END, f.first_seen DESC
