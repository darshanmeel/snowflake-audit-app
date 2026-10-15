-- query_id: access_grants_inventory
-- title: Table and database grants inventory
-- domain: governance_access   tier: standard
-- entity: grant groups = object_scope, privilege_type, GRANTEE
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = an object scope (TABLE or DATABASE) x privilege type x grantee, rolled up.
--   The columns that matter are grant_count (how many individual grants) and distinct_objects (how
--   many different tables and databases that grantee touches).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: live privilege grants to roles by object type (shown as object_scope
--   DATABASE or TABLE), plus role grants to users as object_scope ROLE / USAGE. Grantees are roles
--   or users, never groups.
WITH g AS (
  SELECT IFF(granted_on = 'DATABASE', 'CATALOG', granted_on) AS object_scope, privilege AS privilege_type,
         grantee_name AS grantee, 'ROLE' AS grantee_type,
         granted_on || ':' || COALESCE(table_catalog || '.', '') || COALESCE(table_schema || '.', '') || name AS object_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT 'ROLE', 'USAGE', grantee_name, 'USER', 'ROLE:' || role
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
  WHERE deleted_on IS NULL
)
SELECT 0 AS window_days, object_scope, privilege_type, grantee, grantee_type,
       COUNT(*) AS grant_count, COUNT(DISTINCT object_key) AS distinct_objects
FROM g
GROUP BY object_scope, privilege_type, grantee, grantee_type
ORDER BY object_scope, privilege_type, grantee
