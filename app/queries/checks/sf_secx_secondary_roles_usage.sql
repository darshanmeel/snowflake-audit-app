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
WITH __INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
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
