-- query_id: sf_secx_direct_user_grants
-- shims: USERS, GRANTS_TO_USERS, GRANTS_TO_ROLES
-- reads: INFORMATION_SCHEMA table functions SHOW USERS, SHOW GRANTS OF ROLE (per role), SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role)
-- fallback_note: live users only; no password-change dates; the name stands in for the user id; current role grants to users; current grants to account and database roles; no inherited or future grants
WITH users_ AS (
  SELECT TO_VARCHAR(user_id) AS user_id, name AS user_name, UPPER(login_name) AS login_name,
         COALESCE(UPPER(type), 'PERSON') AS user_type, UPPER(default_role) AS default_role
  FROM __SHIM_USERS__
  WHERE deleted_on IS NULL AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)
),
gu AS (
  SELECT grantee_name AS user_name, role AS role_name
  FROM __SHIM_GRANTS_TO_USERS__
  WHERE deleted_on IS NULL
),
role_users AS (
  SELECT role_name, COUNT(DISTINCT user_name) AS users FROM gu GROUP BY role_name
),
role_parents AS (
  SELECT name AS role_name, COUNT(*) AS parents
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE granted_on = 'ROLE' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND privilege = 'USAGE' AND deleted_on IS NULL
  GROUP BY name
),
role_privs AS (
  SELECT grantee_name AS role_name,
         COUNT_IF(privilege <> 'OWNERSHIP' AND granted_on <> 'ROLE') AS privileges,
         COUNT_IF(privilege = 'OWNERSHIP') AS owned,
         COUNT_IF(granted_on = 'ACCOUNT') AS account_privileges
  FROM __SHIM_GRANTS_TO_ROLES__
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
