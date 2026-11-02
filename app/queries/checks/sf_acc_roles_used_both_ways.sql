-- query_id: sf_acc_roles_used_both_ways
-- title: Access roles handed straight to users
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ROLES, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one custom role that holds object privileges and is granted straight to users.
--   parent_roles lists the custom roles it is also granted to: then it is a building block of a job
--   role, and the users who hold it directly skip that job role.
-- healthy: status = OK when users get the role and no other role is built from it.
-- investigate_if: WARN when the role is also granted to another custom role: access sits on two kinds
--   of role, so a review of job roles misses these users.
-- actions: 1) grant the job role (the parent) to these users and revoke the direct grant (free); 2) keep
--   privileges on access roles and hand users only job roles (free)
-- next: none
-- caveats: found from grant data, not role names, so a role model with one layer reads OK. Database
--   roles are not listed. Lags up to 2 hours.
WITH roles AS (
  SELECT name AS role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL AND COALESCE(role_type, 'ROLE') = 'ROLE'
    AND name NOT IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'SYSADMIN', 'ORGADMIN', 'PUBLIC', 'GLOBALORGADMIN')
),
users_ AS (
  SELECT role AS role_name, COUNT(DISTINCT grantee_name) AS direct_users,
         LISTAGG(DISTINCT grantee_name, ', ') WITHIN GROUP (ORDER BY grantee_name) AS users
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
  WHERE deleted_on IS NULL
  GROUP BY role
),
privs AS (
  SELECT grantee_name AS role_name, COUNT(*) AS privileges
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on IS NULL AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND granted_on NOT IN ('ROLE', 'DATABASE_ROLE')
  GROUP BY grantee_name
),
parents AS (
  SELECT g.name AS role_name, COUNT(DISTINCT g.grantee_name) AS parent_count,
         LISTAGG(DISTINCT g.grantee_name, ', ') WITHIN GROUP (ORDER BY g.grantee_name) AS parent_roles
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
  JOIN roles r ON r.role_name = g.grantee_name
  WHERE g.deleted_on IS NULL AND g.granted_on = 'ROLE' AND g.privilege = 'USAGE' AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
  GROUP BY g.name
),
s AS (
  SELECT r.role_name, u.direct_users, u.users, p.privileges,
         COALESCE(pa.parent_count, 0) AS parent_count, pa.parent_roles
  FROM roles r
  JOIN users_ u ON u.role_name = r.role_name
  JOIN privs p ON p.role_name = r.role_name
  LEFT JOIN parents pa ON pa.role_name = r.role_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, role_name, direct_users, users, privileges,
       parent_count, parent_roles,
       IFF(parent_count > 0, 'granted to users directly and to ' || parent_roles, NULL) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(parent_count > 0, 'WARN', 'OK') AS status
FROM s
ORDER BY CASE status WHEN 'WARN' THEN 0 ELSE 1 END, direct_users DESC, role_name
