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
WITH -- Columns marked sensitive by a tag (Snowflake's SEMANTIC_CATEGORY / PRIVACY_CATEGORY system tags, or a
-- custom tag whose name says PII, sensitive, confidential, PHI, PCI, GDPR, personal or restricted), with
-- whether a masking policy covers them directly or through a tag on the column, table, schema or database.
sf_gov_tag_refs AS (
  SELECT UPPER(tag_database) AS tag_database, UPPER(tag_schema) AS tag_schema, UPPER(tag_name) AS tag_name,
         tag_value, UPPER(domain) AS domain, UPPER(object_database) AS object_database,
         UPPER(object_schema) AS object_schema, UPPER(object_name) AS object_name, UPPER(column_name) AS column_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL
),
-- Which tags mean "sensitive": Snowflake's classification system tags (any value but INSENSITIVE) or a custom
-- tag whose name says so (short acronyms as whole words only, so GEOGRAPHIC is not PHI) with a value that
-- is not a "no" (FALSE, NO, NONE, PUBLIC, INSENSITIVE ...).
sf_gov_sensitive_tagged AS (
  SELECT object_database AS database_name, object_schema AS schema_name, object_name AS table_name, column_name,
         MAX(IFF(tag_database = 'SNOWFLAKE' AND tag_name = 'PRIVACY_CATEGORY', UPPER(tag_value), NULL)) AS privacy_category,
         MAX(IFF(tag_database = 'SNOWFLAKE' AND tag_name = 'SEMANTIC_CATEGORY', UPPER(tag_value), NULL)) AS semantic_category,
         LISTAGG(DISTINCT IFF(tag_database = 'SNOWFLAKE', NULL, tag_database || '.' || tag_schema || '.' || tag_name
                 || COALESCE('=' || tag_value, '')), ', ') AS custom_tags,
         COALESCE(BOOLOR_AGG(tag_database <> 'SNOWFLAKE'
                  AND REGEXP_LIKE(tag_name, '(^|.*[^A-Z0-9])(PII|PHI|PCI)([^A-Z0-9].*|$)')), FALSE) AS has_pii_tag
  FROM sf_gov_tag_refs
  WHERE domain = 'COLUMN'
    AND ((tag_database = 'SNOWFLAKE' AND tag_schema = 'CORE' AND tag_name IN ('PRIVACY_CATEGORY', 'SEMANTIC_CATEGORY')
          AND UPPER(COALESCE(tag_value, '')) <> 'INSENSITIVE')
         OR (tag_database <> 'SNOWFLAKE'
             AND (REGEXP_LIKE(tag_name, '(^|.*[^A-Z0-9])(PII|PHI|PCI|GDPR)([^A-Z0-9].*|$)')
                  OR (REGEXP_LIKE(tag_name, '.*(SENSITIV|CONFIDENTIAL|PERSONAL|RESTRICTED).*')
                      AND NOT REGEXP_LIKE(tag_name, '.*(INSENSITIV|NON.?SENSITIV|NOT.?SENSITIV).*')))
             AND UPPER(COALESCE(tag_value, '')) NOT IN
                 ('FALSE', 'NO', 'N', 'NONE', 'PUBLIC', 'INSENSITIVE', 'NON_SENSITIVE', 'NON-SENSITIVE', 'NOT_SENSITIVE', '0')))
  GROUP BY 1, 2, 3, 4
),
sf_gov_policy_refs AS (
  SELECT policy_kind, UPPER(policy_db || '.' || policy_schema || '.' || policy_name) AS policy_fqn,
         UPPER(ref_database_name) AS ref_database_name, UPPER(ref_schema_name) AS ref_schema_name,
         UPPER(ref_entity_name) AS ref_entity_name, UPPER(ref_entity_domain) AS ref_entity_domain,
         UPPER(ref_column_name) AS ref_column_name, UPPER(tag_database) AS tag_database,
         UPPER(tag_schema) AS tag_schema, UPPER(tag_name) AS tag_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  -- A policy attached but not ACTIVE (for example two masks on one column) does not protect anything.
  WHERE UPPER(policy_status) = 'ACTIVE'
),
-- Tags that carry a masking policy (tag-based masking), as reported either way round.
sf_gov_masking_tags AS (
  SELECT DISTINCT tag_database, tag_schema, tag_name, policy_fqn
  FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND tag_name IS NOT NULL
  UNION
  SELECT DISTINCT ref_database_name, ref_schema_name, ref_entity_name, policy_fqn
  FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND ref_entity_domain = 'TAG'
),
sf_gov_tag_masked AS (
  SELECT r.object_database, r.object_schema, r.object_name, r.column_name, r.domain,
         LISTAGG(DISTINCT m.policy_fqn, ', ') AS policies
  FROM sf_gov_tag_refs r
  JOIN sf_gov_masking_tags m
    ON m.tag_database = r.tag_database AND m.tag_schema = r.tag_schema AND m.tag_name = r.tag_name
  GROUP BY 1, 2, 3, 4, 5
),
sf_gov_sensitive_columns AS (
  SELECT s.*,
         COALESCE(d.policies, tc.policies, tt.policies, ts.policies, tdb.policies) AS masking_policies,
         CASE WHEN d.policies IS NOT NULL THEN 'column policy'
              WHEN tc.policies IS NOT NULL THEN 'tag on column'
              WHEN tt.policies IS NOT NULL THEN 'tag on table'
              WHEN ts.policies IS NOT NULL THEN 'tag on schema'
              WHEN tdb.policies IS NOT NULL THEN 'tag on database' END AS masked_via,
         rap.policies AS row_access_policies
  FROM sf_gov_sensitive_tagged s
  LEFT JOIN (
    SELECT ref_database_name, ref_schema_name, ref_entity_name, ref_column_name, LISTAGG(DISTINCT policy_fqn, ', ') AS policies
    FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND ref_column_name IS NOT NULL
    GROUP BY 1, 2, 3, 4
  ) d ON d.ref_database_name = s.database_name AND d.ref_schema_name = s.schema_name
     AND d.ref_entity_name = s.table_name AND d.ref_column_name = s.column_name
  LEFT JOIN sf_gov_tag_masked tc ON tc.domain = 'COLUMN' AND tc.object_database = s.database_name
     AND tc.object_schema = s.schema_name AND tc.object_name = s.table_name AND tc.column_name = s.column_name
  LEFT JOIN sf_gov_tag_masked tt ON tt.domain = 'TABLE' AND tt.object_database = s.database_name
     AND tt.object_schema = s.schema_name AND tt.object_name = s.table_name
  LEFT JOIN sf_gov_tag_masked ts ON ts.domain = 'SCHEMA' AND ts.object_database = s.database_name
     AND ts.object_name = s.schema_name
  LEFT JOIN sf_gov_tag_masked tdb ON tdb.domain = 'DATABASE' AND tdb.object_name = s.database_name
  LEFT JOIN (
    SELECT ref_database_name, ref_schema_name, ref_entity_name, LISTAGG(DISTINCT policy_fqn, ', ') AS policies
    FROM sf_gov_policy_refs WHERE policy_kind = 'ROW_ACCESS_POLICY'
    GROUP BY 1, 2, 3
  ) rap ON rap.ref_database_name = s.database_name AND rap.ref_schema_name = s.schema_name
     AND rap.ref_entity_name = s.table_name
),
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
