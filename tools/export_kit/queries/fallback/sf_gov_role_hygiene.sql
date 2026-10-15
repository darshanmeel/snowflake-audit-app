-- query_id: sf_gov_role_hygiene
-- shims: ROLES, GRANTS_TO_ROLES, GRANTS_TO_USERS
-- reads: INFORMATION_SCHEMA table functions SHOW ROLES, SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role), SHOW GRANTS OF ROLE (per role)
-- fallback_note: account roles only (no database or instance roles); the name stands in for the role id; current grants to account and database roles; no inherited or future grants; current role grants to users
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
roles AS (
  SELECT o:NAME::VARCHAR AS role_name, o:ROLE_ID::VARCHAR AS role_id, o:OWNER::VARCHAR AS owner_role,
         TRY_TO_TIMESTAMP_LTZ(TO_VARCHAR(o:CREATED_ON)) AS created_on, o:COMMENT::VARCHAR AS role_comment
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o FROM __SHIM_ROLES__)
  WHERE o:DELETED_ON IS NULL AND COALESCE(o:ROLE_TYPE::VARCHAR, 'ROLE') = 'ROLE'
    AND o:NAME::VARCHAR NOT IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'SYSADMIN', 'ORGADMIN', 'PUBLIC',
                                'GLOBALORGADMIN')
),
eff_users AS (
  SELECT role_name, COUNT(DISTINCT user_name) AS effective_users,
         COUNT(DISTINCT IFF(depth = 0, user_name, NULL)) AS direct_users
  FROM sf_sec_user_roles GROUP BY role_name
),
grants AS (
  SELECT grantee_name AS role_name,
         COUNT_IF(granted_on <> 'ROLE') AS privileges,
         COUNT_IF(granted_on = 'ROLE' AND privilege = 'USAGE') AS child_roles
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
  GROUP BY grantee_name
),
parents AS (
  SELECT name AS role_name, COUNT(DISTINCT grantee_name) AS parent_roles
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE granted_on = 'ROLE' AND privilege = 'USAGE' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
  GROUP BY name
),
below AS (
  SELECT top_role, MAX(depth) AS depth_below,
         LISTAGG(DISTINCT IFF(depth > 0 AND role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'ORGADMIN'),
                              role_name, NULL), ', ') AS inherited_admin_roles
  FROM sf_sec_role_reach GROUP BY top_role
),
above AS (
  SELECT role_name, TRUE AS under_sysadmin
  FROM sf_sec_role_reach
  WHERE top_role IN ('SYSADMIN', 'ACCOUNTADMIN') AND depth > 0
  GROUP BY role_name
),
j AS (
  SELECT r.*, COALESCE(e.effective_users, 0) AS effective_users, COALESCE(e.direct_users, 0) AS direct_users,
         COALESCE(g.privileges, 0) AS privileges, COALESCE(g.child_roles, 0) AS child_roles,
         COALESCE(p.parent_roles, 0) AS parent_roles, COALESCE(b.depth_below, 0) AS depth_below,
         NULLIF(b.inherited_admin_roles, '') AS inherited_admin_roles, COALESCE(a.under_sysadmin, FALSE) AS under_sysadmin,
         COUNT(*) OVER () AS custom_roles_total
  FROM roles r
  LEFT JOIN eff_users e ON e.role_name = r.role_name
  LEFT JOIN grants g ON g.role_name = r.role_name
  LEFT JOIN parents p ON p.role_name = r.role_name
  LEFT JOIN below b ON b.top_role = r.role_name
  LEFT JOIN above a ON a.role_name = r.role_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, role_id, role_name, owner_role, created_on, role_comment,
       effective_users, direct_users, privileges, child_roles, parent_roles, depth_below, under_sysadmin,
       inherited_admin_roles, custom_roles_total,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(inherited_admin_roles IS NOT NULL, 'inherits ' || inherited_admin_roles, NULL),
         IFF(effective_users = 0, 'no user can use it', NULL),
         IFF(privileges = 0 AND child_roles = 0, 'holds no privileges or roles', NULL),
         IFF(depth_below > :max_depth, depth_below || ' levels of inherited roles', NULL),
         IFF(NOT under_sysadmin, 'does not roll up to SYSADMIN', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN inherited_admin_roles IS NOT NULL THEN 'CRITICAL'
         WHEN effective_users = 0 OR (privileges = 0 AND child_roles = 0) OR depth_below > :max_depth
              OR NOT under_sysadmin THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, role_name
