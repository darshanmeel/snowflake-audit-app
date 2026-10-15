-- query_id: access_grants_inventory
-- shims: GRANTS_TO_ROLES, GRANTS_TO_USERS
-- reads: INFORMATION_SCHEMA table functions SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role), SHOW GRANTS OF ROLE (per role)
-- fallback_note: current grants to account and database roles; no inherited or future grants; current role grants to users
WITH g AS (
  SELECT IFF(granted_on = 'DATABASE', 'CATALOG', granted_on) AS object_scope, privilege AS privilege_type,
         grantee_name AS grantee, 'ROLE' AS grantee_type,
         granted_on || ':' || COALESCE(table_catalog || '.', '') || COALESCE(table_schema || '.', '') || name AS object_key
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT 'ROLE', 'USAGE', grantee_name, 'USER', 'ROLE:' || role
  FROM __SHIM_GRANTS_TO_USERS__
  WHERE deleted_on IS NULL
)
SELECT 0 AS window_days, object_scope, privilege_type, grantee, grantee_type,
       COUNT(*) AS grant_count, COUNT(DISTINCT object_key) AS distinct_objects
FROM g
GROUP BY object_scope, privilege_type, grantee, grantee_type
ORDER BY object_scope, privilege_type, grantee
