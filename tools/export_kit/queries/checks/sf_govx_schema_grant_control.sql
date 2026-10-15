-- query_id: sf_govx_schema_grant_control
-- title: Schemas where object owners hand out access instead of the schema owner
-- domain: governance_access   tier: standard
-- entity: schemas = schema_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :warn_owners (default 3) owners: at or above this the row reads WARN; :warn_grantors (default
--   3) grantors: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live schema that holds objects with grants. is_managed_access is TRUE when
--   only the schema owner (or MANAGE GRANTS) can grant on its objects. object_owners counts roles
--   owning objects in it other than the schema owner; grantors counts roles that granted privileges on
--   its objects; sensitive_objects counts tables and views with a column tagged sensitive.
-- healthy: status = OK when the schema is managed access, or one role owns and grants everything in it.
-- investigate_if: WARN when a regular schema has :warn_owners+ other owning roles or :warn_grantors+
--   grantors (access is decided object by object, by whoever created it); CRITICAL when such a schema
--   also holds sensitive-tagged objects.
-- actions: 1) ALTER SCHEMA ... ENABLE MANAGED ACCESS so grants go through the schema owner (config); 2)
--   GRANT OWNERSHIP ON ALL ... IN SCHEMA to one functional role, COPY CURRENT GRANTS (free); 3) use
--   future grants on the schema instead of per-object grants (config)
-- next: none
-- caveats: future grants (SHOW FUTURE GRANTS IN SCHEMA) are not in ACCOUNT_USAGE, so a schema run
--   purely on future grants shows few grantors; SNOWFLAKE and INFORMATION_SCHEMA are left out. Lags up
--   to 2 hours.
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
sch AS (
  SELECT catalog_name AS database_name, schema_name, schema_owner, is_managed_access = 'YES' AS is_managed_access
  FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
  WHERE deleted IS NULL AND schema_name <> 'INFORMATION_SCHEMA' AND catalog_name <> 'SNOWFLAKE'
),
g AS (
  SELECT table_catalog AS database_name, table_schema AS schema_name, name AS object_name, privilege,
         grantee_name, granted_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL AND table_schema IS NOT NULL
    AND granted_on NOT IN ('SCHEMA', 'DATABASE', 'ACCOUNT')
),
sensitive AS (
  SELECT database_name, schema_name, COUNT(DISTINCT table_name) AS sensitive_objects
  FROM sf_gov_sensitive_tagged
  GROUP BY 1, 2
),
agg AS (
  SELECT g.database_name, g.schema_name,
         COUNT(DISTINCT g.object_name) AS objects,
         COUNT(DISTINCT IFF(g.privilege = 'OWNERSHIP' AND g.grantee_name <> s.schema_owner, g.grantee_name, NULL)) AS object_owners,
         LISTAGG(DISTINCT IFF(g.privilege = 'OWNERSHIP' AND g.grantee_name <> s.schema_owner, g.grantee_name, NULL), ', ') AS object_owner_roles,
         COUNT(DISTINCT IFF(g.privilege <> 'OWNERSHIP', g.granted_by, NULL)) AS grantors,
         LISTAGG(DISTINCT IFF(g.privilege <> 'OWNERSHIP', g.granted_by, NULL), ', ') AS grantor_roles,
         COUNT_IF(g.privilege <> 'OWNERSHIP') AS object_grants
  FROM g
  JOIN sch s ON s.database_name = g.database_name AND s.schema_name = g.schema_name
  GROUP BY 1, 2
),
j AS (
  SELECT s.*, a.objects, a.object_owners, NULLIF(a.object_owner_roles, '') AS object_owner_roles, a.grantors,
         NULLIF(a.grantor_roles, '') AS grantor_roles, a.object_grants,
         COALESCE(t.sensitive_objects, 0) AS sensitive_objects,
         (NOT s.is_managed_access AND (a.object_owners >= :warn_owners OR a.grantors >= :warn_grantors)) AS decentralised
  FROM sch s
  JOIN agg a ON a.database_name = s.database_name AND a.schema_name = s.schema_name
  LEFT JOIN sensitive t ON t.database_name = UPPER(s.database_name) AND t.schema_name = UPPER(s.schema_name)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name,
       database_name || '.' || schema_name AS schema_fqn, schema_owner, is_managed_access, objects, object_owners,
       object_owner_roles, grantors, grantor_roles, object_grants, sensitive_objects,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NOT is_managed_access, 'not managed access', NULL),
         IFF(object_owners >= :warn_owners, object_owners || ' other roles own objects', NULL),
         IFF(grantors >= :warn_grantors, grantors || ' roles granted access', NULL),
         IFF(sensitive_objects > 0, sensitive_objects || ' objects with sensitive columns', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN decentralised AND sensitive_objects > 0 THEN 'CRITICAL'
         WHEN decentralised THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, grantors DESC, object_owners DESC
