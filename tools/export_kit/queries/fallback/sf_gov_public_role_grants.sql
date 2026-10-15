-- query_id: sf_gov_public_role_grants
-- shims: GRANTS_TO_ROLES
-- reads: INFORMATION_SCHEMA table functions SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role)
-- fallback_note: current grants to account and database roles; no inherited or future grants
WITH g AS (
  SELECT privilege, granted_on AS object_type, name AS object_name, table_catalog, table_schema,
         COALESCE(table_catalog || '.', '') || COALESCE(table_schema || '.', '') || name AS object_fqn,
         LOWER(TO_VARCHAR(grant_option)) = 'true' AS grant_option, granted_by, created_on
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE grantee_name = 'PUBLIC' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
),
k AS (
  SELECT g.*,
         (COALESCE(table_catalog, object_name) IN ('SNOWFLAKE_SAMPLE_DATA', 'SNOWFLAKE')) AS is_sample_or_system,
         CASE
           WHEN privilege = 'OWNERSHIP' OR object_type IN ('ROLE', 'ACCOUNT', 'INTEGRATION', 'USER')
                OR privilege IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'WRITE', 'CREATE SCHEMA', 'CREATE TABLE',
                                 'CREATE STAGE', 'MODIFY', 'APPLY')
                OR grant_option THEN 'CRITICAL'
           WHEN object_type IN ('FUNCTION', 'PROCEDURE', 'FILE_FORMAT', 'SEQUENCE') THEN 'OK'
           ELSE 'WARN'
         END AS base_status
  FROM g
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, privilege, object_type, object_fqn, object_name,
       table_catalog AS database_name, table_schema AS schema_name, grant_option, granted_by AS granted_by_role,
       created_on AS granted_on_time, is_sample_or_system,
       'PUBLIC has ' || privilege || ' on ' || object_type || ' ' || object_fqn
         || IFF(grant_option, ' with grant option', '') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE WHEN is_sample_or_system AND base_status = 'WARN' THEN 'OK' ELSE base_status END AS status
FROM k
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, object_type, object_fqn
