-- query_id: sf_gov_ownership_concentration
-- shims: GRANTS_TO_ROLES, GRANTS_TO_USERS, ROLES
-- reads: INFORMATION_SCHEMA table functions SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role), SHOW GRANTS OF ROLE (per role), SHOW ROLES
-- fallback_note: current grants to account and database roles; no inherited or future grants; current role grants to users; account roles only (no database or instance roles); the name stands in for the role id
WITH own AS (
  SELECT grantee_name AS owner_role, granted_on AS object_type,
         COALESCE(table_catalog || '.', '') || COALESCE(table_schema || '.', '') || name AS object_fqn,
         -- A sample, not the full list: an owner can hold millions of objects.
         ROW_NUMBER() OVER (PARTITION BY grantee_name, granted_on ORDER BY created_on DESC) AS rn
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE privilege = 'OWNERSHIP' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
),
users_per_role AS (
  SELECT role, COUNT(DISTINCT grantee_name) AS users, MAX(grantee_name) AS only_user
  FROM __SHIM_GRANTS_TO_USERS__
  WHERE deleted_on IS NULL
  GROUP BY role
),
parents AS (
  SELECT name AS role, COUNT(DISTINCT grantee_name) AS parent_roles
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE granted_on = 'ROLE' AND privilege = 'USAGE' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
  GROUP BY name
),
roles AS (
  SELECT r.name AS role_name,
         r.name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'ORGADMIN') AS is_admin,
         (r.name NOT IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'ORGADMIN', 'SYSADMIN', 'PUBLIC')
          AND COALESCE(u.users, 0) = 1 AND COALESCE(p.parent_roles, 0) = 0) AS is_personal,
         IFF(COALESCE(u.users, 0) = 1, u.only_user, NULL) AS user_name
  FROM __SHIM_ROLES__ r
  LEFT JOIN users_per_role u ON u.role = r.name
  LEFT JOIN parents p ON p.role = r.name
  WHERE r.deleted_on IS NULL
),
agg AS (
  SELECT o.owner_role, o.object_type, r.is_admin, r.is_personal, r.user_name,
         o.object_type NOT IN ('ROLE', 'USER', 'INTEGRATION', 'NETWORK_POLICY', 'ACCOUNT', 'RESOURCE_MONITOR',
                               'DATABASE_ROLE', 'APPLICATION', 'SHARE') AS is_data_object,
         COUNT(*) AS objects,
         LISTAGG(IFF(o.rn <= 10, o.object_fqn, NULL), ', ') AS sample_objects
  FROM own o
  JOIN roles r ON r.role_name = o.owner_role
  WHERE r.is_admin OR r.is_personal
  GROUP BY 1, 2, 3, 4, 5, 6
),
f AS (
  SELECT a.*,
         SUM(IFF(is_admin AND is_data_object, objects, 0)) OVER (PARTITION BY owner_role) AS admin_data_objects,
         SUM(IFF(is_personal, objects, 0)) OVER (PARTITION BY owner_role) AS personal_objects
  FROM agg a
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, owner_role, IFF(is_admin, 'admin', 'personal') AS role_kind,
       user_name, object_type, is_data_object, objects, sample_objects,
       admin_data_objects, personal_objects,
       owner_role || ' owns ' || objects || ' ' || object_type || ' objects'
         || IFF(is_personal, ' (a personal role)', '') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN is_admin AND is_data_object AND admin_data_objects >= :crit_admin_owned THEN 'CRITICAL'
         WHEN is_admin AND is_data_object AND admin_data_objects >= :warn_admin_owned THEN 'WARN'
         WHEN is_personal AND personal_objects >= :warn_personal_owned THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, objects DESC
