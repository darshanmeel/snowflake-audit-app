-- query_id: sf_secx_secondary_roles_usage
-- title: Users whose sessions activate all their roles at once
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_roles (default 10) roles: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one enabled user whose DEFAULT_SECONDARY_ROLES is ALL, or who ran queries with
--   secondary roles in the window. reachable_roles counts every role the user can use; with ALL, the
--   privileges of all of them apply to every query (only CREATE uses the primary role). admin_roles
--   lists admin roles among them; secondary_role_queries counts queries in the window whose
--   SECONDARY_ROLE_STATS is filled, and sample_secondary_roles shows one such value.
-- healthy: status = OK when the user has few, non-admin roles, or sessions use one primary role.
-- investigate_if: WARN when all secondary roles are active and the user can use :warn_roles+ roles, or
--   SYSADMIN / USERADMIN; CRITICAL when ACCOUNTADMIN, SECURITYADMIN or ORGADMIN is active as a
--   secondary role, so admin privileges apply silently to everyday queries.
-- actions: 1) ALTER USER ... SET DEFAULT_SECONDARY_ROLES = () for admins and service users (free); 2)
--   use a session policy with ALLOWED_SECONDARY_ROLES to limit them account-wide (config); 3) move
--   admin roles to separate admin users (free)
-- next: none
-- caveats: SECONDARY_ROLE_STATS is a newer QUERY_HISTORY column; users can also run USE SECONDARY ROLES
--   themselves, which only that column shows. Grants lag up to 2 hours, queries up to 45 minutes.
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
reach AS (
  SELECT user_name, COUNT(DISTINCT role_name) AS reachable_roles,
         LISTAGG(DISTINCT IFF(role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'SYSADMIN', 'USERADMIN'), role_name, NULL), ', ') AS admin_roles,
         BOOLOR_AGG(role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN')) AS has_top_admin
  FROM sf_sec_user_roles
  GROUP BY user_name
),
q AS (
  SELECT user_name, COUNT(*) AS queries,
         COUNT_IF(NULLIF(TRIM(TO_VARCHAR(secondary_role_stats)), '') IS NOT NULL) AS secondary_role_queries,
         MAX(LEFT(TO_VARCHAR(secondary_role_stats), 300)) AS sample_secondary_roles
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY user_name
),
j AS (
  SELECT u.user_id, u.user_name, u.user_type, u.default_role, u.default_secondary_role,
         COALESCE(u.default_secondary_role LIKE '%ALL%', FALSE) AS all_secondary,
         COALESCE(r.reachable_roles, 0) AS reachable_roles, NULLIF(r.admin_roles, '') AS admin_roles,
         COALESCE(r.has_top_admin, FALSE) AS has_top_admin,
         COALESCE(q.queries, 0) AS queries, COALESCE(q.secondary_role_queries, 0) AS secondary_role_queries,
         q.sample_secondary_roles
  FROM sf_sec_users u
  LEFT JOIN reach r ON r.user_name = u.user_name
  LEFT JOIN q ON q.user_name = u.user_name
  WHERE NOT u.is_disabled
),
s AS (
  SELECT j.*, (all_secondary OR secondary_role_queries > 0) AS secondary_active,
         CASE
           WHEN (all_secondary OR secondary_role_queries > 0) AND has_top_admin THEN 'CRITICAL'
           WHEN (all_secondary OR secondary_role_queries > 0)
                AND (reachable_roles >= :warn_roles OR admin_roles IS NOT NULL) THEN 'WARN'
           ELSE 'OK'
         END AS status
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, user_type, default_role,
       default_secondary_role, reachable_roles, admin_roles, queries, secondary_role_queries, sample_secondary_roles,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(all_secondary, 'DEFAULT_SECONDARY_ROLES = ALL', NULL),
         IFF(secondary_role_queries > 0, secondary_role_queries || ' queries ran with secondary roles', NULL),
         IFF(reachable_roles >= :warn_roles, reachable_roles || ' roles active together', NULL),
         IFF(admin_roles IS NOT NULL, 'admin roles active as secondary: ' || admin_roles, NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       status
FROM s
WHERE secondary_active
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, reachable_roles DESC
