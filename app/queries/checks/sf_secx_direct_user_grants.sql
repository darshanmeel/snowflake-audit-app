-- query_id: sf_secx_direct_user_grants
-- title: Users with many direct role grants or a personal role that holds privileges
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :warn_direct_roles (default 8) direct roles: at or above this the row reads WARN;
--   :crit_direct_roles (default 20) direct roles: at or above this the row reads CRITICAL;
--   :warn_personal_privileges (default 10) personal privileges: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one enabled user with role grants. direct_roles counts roles granted straight to
--   the user; personal_roles lists custom roles granted to this user only and to no other role (or
--   named after the user), i.e. access given to a person rather than to a job; personal_privileges
--   counts object privileges (not ownership) those personal roles hold, personal_owned how many objects
--   they own.
-- healthy: status = OK when the user gets a few functional roles and privileges sit on shared roles.
-- investigate_if: WARN when a user has :warn_direct_roles+ direct roles, or a personal role holds
--   :warn_personal_privileges+ privileges; CRITICAL at :crit_direct_roles+ direct roles, or when a
--   personal role holds an account-level privilege (access that no role review will see as belonging to
--   a job).
-- actions: 1) replace scattered direct grants with one functional role per job and grant that (free);
--   2) move privileges off personal roles onto functional roles, then drop them (free); 3) manage
--   grants via SCIM groups or code so they are reviewable (config)
-- next: none
-- caveats: the personal-role guess is structural or by name; database roles granted to users through
--   roles are not listed. Snowflake object privileges go to roles, so direct role grants are the only
--   per-user grants. Lags up to 2 hours.
WITH users_ AS (
  SELECT TO_VARCHAR(user_id) AS user_id, name AS user_name, UPPER(login_name) AS login_name,
         COALESCE(UPPER(type), 'PERSON') AS user_type, UPPER(default_role) AS default_role
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)
),
gu AS (
  SELECT grantee_name AS user_name, role AS role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
  WHERE deleted_on IS NULL
),
role_users AS (
  SELECT role_name, COUNT(DISTINCT user_name) AS users FROM gu GROUP BY role_name
),
role_parents AS (
  SELECT name AS role_name, COUNT(*) AS parents
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE granted_on = 'ROLE' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND privilege = 'USAGE' AND deleted_on IS NULL
  GROUP BY name
),
role_privs AS (
  SELECT grantee_name AS role_name,
         COUNT_IF(privilege <> 'OWNERSHIP' AND granted_on <> 'ROLE') AS privileges,
         COUNT_IF(privilege = 'OWNERSHIP') AS owned,
         COUNT_IF(granted_on = 'ACCOUNT') AS account_privileges
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
  GROUP BY grantee_name
),
per_role AS (
  SELECT g.user_name, g.role_name,
         (g.role_name NOT IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'SYSADMIN', 'ORGADMIN', 'PUBLIC')
          AND ((ru.users = 1 AND COALESCE(rp.parents, 0) = 0)
               OR CONTAINS(g.role_name, UPPER(g.user_name)) OR CONTAINS(g.role_name, u.login_name))) AS is_personal,
         COALESCE(p.privileges, 0) AS privileges, COALESCE(p.owned, 0) AS owned,
         COALESCE(p.account_privileges, 0) AS account_privileges
  FROM gu g
  JOIN users_ u ON u.user_name = g.user_name
  LEFT JOIN role_users ru ON ru.role_name = g.role_name
  LEFT JOIN role_parents rp ON rp.role_name = g.role_name
  LEFT JOIN role_privs p ON p.role_name = g.role_name
),
agg AS (
  SELECT user_name, COUNT(DISTINCT role_name) AS direct_roles,
         LISTAGG(DISTINCT role_name, ', ') WITHIN GROUP (ORDER BY role_name) AS direct_role_list,
         LISTAGG(DISTINCT IFF(is_personal, role_name, NULL), ', ') WITHIN GROUP (ORDER BY IFF(is_personal, role_name, NULL)) AS personal_roles,
         SUM(IFF(is_personal, privileges, 0)) AS personal_privileges,
         SUM(IFF(is_personal, owned, 0)) AS personal_owned,
         SUM(IFF(is_personal, account_privileges, 0)) AS personal_account_privileges
  FROM per_role
  GROUP BY user_name
),
s AS (
  SELECT u.user_id, u.user_name, u.user_type, u.default_role, a.direct_roles, a.direct_role_list,
         a.personal_roles, a.personal_privileges, a.personal_owned, a.personal_account_privileges,
         CASE
           WHEN a.direct_roles >= :crit_direct_roles OR a.personal_account_privileges > 0 THEN 'CRITICAL'
           WHEN a.direct_roles >= :warn_direct_roles OR a.personal_privileges >= :warn_personal_privileges THEN 'WARN'
           ELSE 'OK'
         END AS status
  FROM users_ u
  JOIN agg a ON a.user_name = u.user_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, user_type, default_role,
       direct_roles, direct_role_list, personal_roles, personal_privileges, personal_owned,
       personal_account_privileges,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(direct_roles >= :warn_direct_roles, direct_roles || ' roles granted directly', NULL),
         IFF(personal_roles IS NOT NULL AND personal_roles <> '', 'personal roles: ' || personal_roles, NULL),
         IFF(personal_privileges > 0, personal_privileges || ' privileges held by personal roles', NULL),
         IFF(personal_account_privileges > 0, 'a personal role holds account-level privileges', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, direct_roles DESC, personal_privileges DESC
