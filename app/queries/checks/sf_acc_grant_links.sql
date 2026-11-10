-- query_id: sf_acc_grant_links
-- title: Every live grant link: users to roles, roles to roles, roles to objects
-- domain: governance_access   tier: standard
-- entity: grant links = link_kind, grantee, name, privilege
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live grant link (user_role, role_role, role_object) or one user (user).
--   The Access explorer walks these links to show every path from a user through roles to an object.
--   Database roles are nodes named DATABASE.ROLE; application roles are objects.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: current grants only; future grants are not in ACCOUNT_USAGE. Every user also holds PUBLIC,
--   which has no user_role row. USAGE on the database and schema is not required for a path to show.
--   On a very large account the export row cap can cut this list. Lags up to 2 hours.
WITH __INCLUDE_sf_sec_users__,
g AS (
  SELECT *,
         -- A database role is named DATABASE.ROLE; it can only hold privileges in its own database.
         IFF(granted_to = 'DATABASE_ROLE' AND NOT CONTAINS(grantee_name, '.'),
             COALESCE(IFF(granted_on = 'DATABASE', name, table_catalog), '?') || '.' || grantee_name,
             grantee_name) AS grantee_node
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on IS NULL AND granted_to IN ('ROLE', 'ACCOUNT ROLE', 'DATABASE_ROLE')
)
SELECT * FROM (
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, 'user' AS link_kind, user_name AS grantee,
       'USER' AS grantee_type, default_role AS name, 'USER' AS granted_on, CAST(NULL AS VARCHAR) AS privilege,
       CAST(NULL AS VARCHAR) AS database_name, CAST(NULL AS VARCHAR) AS schema_name, FALSE AS grant_option,
       user_type, is_disabled, last_success_login, default_role
FROM sf_sec_users
UNION ALL
SELECT 0, __ACCOUNT_ID__, 'user_role', grantee_name, 'USER', role, 'ROLE', 'USAGE', NULL, NULL, FALSE,
       NULL, NULL, NULL, NULL
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE deleted_on IS NULL
UNION ALL
SELECT 0, __ACCOUNT_ID__, IFF(granted_on IN ('ROLE', 'DATABASE_ROLE') AND privilege = 'USAGE', 'role_role', 'role_object'),
       grantee_node, IFF(granted_to = 'DATABASE_ROLE', 'DATABASE_ROLE', 'ROLE'),
       CASE
         WHEN granted_on = 'DATABASE_ROLE' THEN IFF(CONTAINS(name, '.'), name, table_catalog || '.' || name)
         -- Some names come back already qualified.
         WHEN STARTSWITH(name, table_catalog || '.') THEN name
         WHEN granted_on IN ('DATABASE', 'ACCOUNT', 'ROLE') OR table_catalog IS NULL THEN name
         -- A schema name can come back already qualified as DATABASE.SCHEMA.
         WHEN granted_on = 'SCHEMA' THEN IFF(CONTAINS(name, '.'), name, table_catalog || '.' || name)
         WHEN table_schema IS NULL THEN table_catalog || '.' || name
         ELSE IFF(CONTAINS(table_schema, '.'), table_schema, table_catalog || '.' || table_schema) || '.' || name
       END,
       granted_on, privilege, IFF(granted_on = 'DATABASE', name, table_catalog),
       IFF(granted_on = 'SCHEMA', IFF(CONTAINS(name, '.'), SPLIT_PART(name, '.', 2), name),
           IFF(CONTAINS(table_schema, '.'), SPLIT_PART(table_schema, '.', 2), table_schema)),
       COALESCE(grant_option, FALSE),
       NULL, NULL, NULL, NULL
FROM g
)
-- Users and role links first: when the export's row cap cuts, it cuts role-to-object grants, not who holds what.
ORDER BY CASE link_kind WHEN 'user' THEN 0 WHEN 'user_role' THEN 1 WHEN 'role_role' THEN 2 ELSE 3 END, grantee, name, privilege
