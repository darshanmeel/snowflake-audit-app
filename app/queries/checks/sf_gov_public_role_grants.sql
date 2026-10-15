-- query_id: sf_gov_public_role_grants
-- title: Privileges granted to PUBLIC
-- domain: governance_access   tier: standard
-- entity: objects = object_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live privilege held by the PUBLIC role, which every user and role in the
--   account has. object_fqn is the object; object_type is what GRANTED_ON reports (TABLE, VIEW,
--   DATABASE, WAREHOUSE, INTEGRATION, ROLE ...).
-- healthy: status = OK for USAGE on functions, procedures and file formats, and on the Snowflake sample
--   data.
-- investigate_if: WARN for USAGE on databases, schemas, warehouses and stages, or read access to data
--   (SELECT, READ) that is not sample data; CRITICAL when PUBLIC can write or own anything, holds a
--   role, an integration or an account-level privilege.
-- actions: 1) REVOKE the privilege from PUBLIC and grant it to a functional role instead (free); 2)
--   check future grants on schemas for PUBLIC (SHOW FUTURE GRANTS IN SCHEMA) so it does not come back
--   (free)
-- next: none
-- caveats: future grants are not in ACCOUNT_USAGE, so only existing objects are seen. Lags up to 2
--   hours.
WITH g AS (
  SELECT privilege, granted_on AS object_type, name AS object_name, table_catalog, table_schema,
         COALESCE(table_catalog || '.', '') || COALESCE(table_schema || '.', '') || name AS object_fqn,
         LOWER(TO_VARCHAR(grant_option)) = 'true' AS grant_option, granted_by, created_on
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
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
