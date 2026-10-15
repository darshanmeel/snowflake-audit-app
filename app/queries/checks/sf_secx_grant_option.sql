-- query_id: sf_secx_grant_option
-- title: Privileges held WITH GRANT OPTION outside the admin roles
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA,
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :warn_grants (default 1) grants: at or above this the row reads WARN; :crit_sensitive_objects
--   (default 1) sensitive objects: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one role x object type x privilege held WITH GRANT OPTION (ownership excluded:
--   owners can always re-grant). grants counts the objects; sample_objects shows up to 10;
--   in_managed_schema counts those in managed access schemas, where the option has no effect;
--   sensitive_objects counts tables and views with a column tagged as sensitive (SEMANTIC_CATEGORY /
--   PRIVACY_CATEGORY or a PII-like custom tag).
-- healthy: status = OK when only ACCOUNTADMIN / SECURITYADMIN / SYSADMIN / USERADMIN hold grant
--   options, or every grant sits in a managed access schema.
-- investigate_if: WARN when another role can pass on a privilege on :warn_grants+ objects outside
--   managed access; CRITICAL when PUBLIC holds a grant option, the privilege is account-level, or it
--   covers :crit_sensitive_objects+ objects with sensitive columns.
-- actions: 1) REVOKE GRANT OPTION FOR <privilege> ON ... FROM ROLE ... and grant it again without it
--   (free); 2) make data schemas managed access (ALTER SCHEMA ... ENABLE MANAGED ACCESS) so only the
--   schema owner grants (config)
-- next: none
-- caveats: future grants are not in ACCOUNT_USAGE; tags are matched by name, not by value. Lags up to 2
--   hours.
WITH __INCLUDE_sf_gov_sensitive_columns__,
g AS (
  SELECT grantee_name AS role_name, granted_on AS object_type, privilege, name AS object_name,
         table_catalog AS database_name, table_schema AS schema_name, granted_by,
         CASE WHEN granted_on = 'ACCOUNT' THEN 'ACCOUNT'
              WHEN granted_on = 'DATABASE' THEN name
              WHEN granted_on = 'SCHEMA' THEN table_catalog || '.' || name
              WHEN table_schema IS NOT NULL THEN table_catalog || '.' || table_schema || '.' || name
              ELSE name END AS object_fqn
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL AND privilege <> 'OWNERSHIP'
    AND LOWER(TO_VARCHAR(grant_option)) = 'true'
),
managed AS (
  SELECT catalog_name AS database_name, schema_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
  WHERE deleted IS NULL AND is_managed_access = 'YES'
),
sensitive AS (
  SELECT DISTINCT database_name, schema_name, table_name AS object_name
  FROM sf_gov_sensitive_tagged
),
j AS (
  SELECT g.*, m.schema_name IS NOT NULL AS in_managed, s.object_name IS NOT NULL AS is_sensitive
  FROM g
  LEFT JOIN managed m ON m.database_name = g.database_name AND m.schema_name = g.schema_name
  LEFT JOIN sensitive s ON s.database_name = UPPER(g.database_name) AND s.schema_name = UPPER(g.schema_name)
   AND s.object_name = UPPER(g.object_name)
),
agg AS (
  SELECT role_name, object_type, privilege, COUNT(*) AS grants, COUNT_IF(in_managed) AS in_managed_schema,
         COUNT_IF(is_sensitive AND NOT in_managed) AS sensitive_objects,
         LISTAGG(DISTINCT granted_by, ', ') WITHIN GROUP (ORDER BY granted_by) AS granted_by_roles,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(object_fqn) WITHIN GROUP (ORDER BY is_sensitive DESC, object_fqn), 0, 10), ', ') AS sample_objects
  FROM j
  GROUP BY role_name, object_type, privilege
),
s AS (
  SELECT agg.*, (role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'USERADMIN', 'ORGADMIN')) AS is_admin_role,
         grants - in_managed_schema AS effective_grants
  FROM agg
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, role_name, object_type, privilege, grants,
       in_managed_schema, effective_grants, sensitive_objects, granted_by_roles, sample_objects, is_admin_role,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(role_name = 'PUBLIC', 'PUBLIC can re-grant this', NULL),
         IFF(object_type = 'ACCOUNT' AND NOT is_admin_role, 'account-level privilege with grant option', NULL),
         IFF(sensitive_objects > 0, sensitive_objects || ' objects with sensitive columns', NULL),
         IFF(effective_grants > 0 AND NOT is_admin_role, effective_grants || ' objects outside managed access', NULL),
         IFF(effective_grants = 0, 'all in managed access schemas', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN role_name = 'PUBLIC' THEN 'CRITICAL'
         WHEN is_admin_role THEN 'OK'
         WHEN object_type = 'ACCOUNT' OR sensitive_objects >= :crit_sensitive_objects THEN 'CRITICAL'
         WHEN effective_grants >= :warn_grants THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, sensitive_objects DESC, grants DESC
