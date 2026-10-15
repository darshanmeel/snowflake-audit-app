-- query_id: sf_secx_session_policy_coverage
-- title: People whose sessions have no idle timeout policy, or a long one
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SESSION_POLICIES, SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- not_assessed_reasons: policy_attachment_not_listed: a session policy exists but Snowflake does not list
--   where it is attached (POLICY_REFERENCES leaves out session policies)
-- read_this: one row = one enabled PERSON user who signed in during the window. defined_policies is how
--   many session policies exist in the account. With none, every session keeps the 240-minute idle
--   default. With one or more, whether a user is covered cannot be read here, so the row is not
--   assessed. admin_roles lists admin roles the user can use.
-- healthy: n/a - with no session policy every row flags; with one the row cannot be judged.
-- investigate_if: WARN when no session policy exists; CRITICAL when that user can use ACCOUNTADMIN,
--   SECURITYADMIN, ORGADMIN or USERADMIN.
-- actions: 1) CREATE SESSION POLICY with short idle timeouts and ALTER ACCOUNT SET SESSION POLICY
--   (config); 2) attach a stricter session policy to admin users (config); 3) confirm attachment with
--   SHOW PARAMETERS or the INFORMATION_SCHEMA.POLICY_REFERENCES table function (free)
-- next: none
-- caveats: service users are left out (their drivers keep sessions alive on purpose). POLICY_REFERENCES
--   does not list session policies, so an attached policy is not visible. Lags up to 2 hours.
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
-- DATABASE and SCHEMA are reserved words, so read the row as an object.
sp AS (
  SELECT o:ID::NUMBER AS policy_id,
         o:DATABASE::VARCHAR || '.' || o:SCHEMA::VARCHAR || '.' || o:NAME::VARCHAR AS policy_fqn,
         o:SESSION_IDLE_TIMEOUT_MINS::NUMBER AS session_idle_timeout_mins,
         o:SESSION_UI_IDLE_TIMEOUT_MINS::NUMBER AS session_ui_idle_timeout_mins
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o FROM SNOWFLAKE.ACCOUNT_USAGE.SESSION_POLICIES)
  WHERE o:DELETED IS NULL
),
defs AS (
  SELECT COUNT(*) AS defined_policies FROM sp
),
admin AS (
  SELECT user_name, LISTAGG(DISTINCT role_name, ', ') WITHIN GROUP (ORDER BY role_name) AS admin_roles
  FROM sf_sec_user_roles
  WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN')
  GROUP BY user_name
),
logins AS (
  SELECT user_name, COUNT(*) AS logins, MAX(event_timestamp) AS last_login
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
    AND is_success = 'YES'
  GROUP BY user_name
),
j AS (
  SELECT u.user_id, u.user_name, u.user_type, a.admin_roles, l.logins, l.last_login,
         d.defined_policies
  FROM sf_sec_users u
  JOIN logins l ON l.user_name = u.user_name
  LEFT JOIN admin a ON a.user_name = u.user_name
  CROSS JOIN defs d
  WHERE NOT u.is_disabled AND u.user_type = 'PERSON'
),
s AS (
  SELECT j.*
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, user_type, admin_roles,
       logins, last_login, defined_policies,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(defined_policies = 0, 'no session policy exists (240-minute default)', NULL),
         IFF(admin_roles IS NOT NULL, 'can use ' || admin_roles, NULL)), '; ') AS reasons,
       IFF(defined_policies > 0, 'policy_attachment_not_listed', NULL) AS not_assessed_reason,
       CASE
         WHEN defined_policies > 0 THEN 'NOT_ASSESSED'
         WHEN admin_roles IS NOT NULL THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, logins DESC
