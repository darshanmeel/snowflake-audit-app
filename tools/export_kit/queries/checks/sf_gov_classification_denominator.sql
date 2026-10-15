-- query_id: sf_gov_classification_denominator
-- title: Columns carrying a sensitive or semantic tag, out of all columns, per database
-- domain: governance_access   tier: standard
-- entity: databases = database_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.COLUMNS, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (tags and masking policies)
-- params: :min_columns (default 50) columns: a database with fewer is never flagged
-- empty_if: edition_too_low, role_cannot_see
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. COLUMNS is large; the count is one pass over it.
-- read_this: one row = one database. total_columns is every live column in it (tables and views), tagged_columns
--   those carrying Snowflake's SEMANTIC_CATEGORY or PRIVACY_CATEGORY tag or a custom sensitive tag, masked_columns
--   the tagged ones a masking policy reaches. tagged_pct = tagged_columns / total_columns. It is the
--   denominator for "N of M columns classified"; a low share is normal, since most columns are not sensitive.
-- healthy: status = OK when the database has tagged columns, or it is small.
-- investigate_if: WARN when a database with at least :min_columns columns has no tagged column at all: nothing
--   is known about what is sensitive in it.
-- actions: 1) run classification on the databases that hold customer data (SYSTEM$CLASSIFY, or a
--   classification profile) (free); 2) apply the recommended tags (config); 3) put masking policies on the tags
--   so tagged columns are masked (config)
-- next: sf_gov_classification_coverage
-- caveats: Only columns of live tables and views are counted; shared and imported databases may be missing
--   from COLUMNS. INFORMATION_SCHEMA and the SNOWFLAKE database are left out. Database names are matched
--   ignoring case. Tag masking through a tag the column does not carry is not seen.
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
c AS (
  SELECT UPPER(col.table_catalog) AS db_key, MAX(col.table_catalog) AS database_name, COUNT(*) AS total_columns,
         COUNT(DISTINCT col.table_schema || '.' || col.table_name) AS objects
  FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS col
  WHERE col.deleted IS NULL AND UPPER(col.table_catalog) <> 'SNOWFLAKE' AND UPPER(col.table_schema) <> 'INFORMATION_SCHEMA'
  GROUP BY 1
),
t AS (
  SELECT UPPER(database_name) AS db_key, COUNT(*) AS tagged_columns, COUNT_IF(masking_policies IS NOT NULL) AS masked_columns
  FROM sf_gov_sensitive_columns
  GROUP BY 1
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, c.database_name, c.objects AS tables_and_views, c.total_columns,
       COALESCE(t.tagged_columns, 0) AS tagged_columns, COALESCE(t.masked_columns, 0) AS masked_columns,
       100 * COALESCE(t.tagged_columns, 0) / NULLIF(c.total_columns, 0) AS tagged_pct,
       IFF(COALESCE(t.tagged_columns, 0) = 0 AND c.total_columns >= :min_columns,
           'no column carries a sensitive or semantic tag', NULL) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(COALESCE(t.tagged_columns, 0) = 0 AND c.total_columns >= :min_columns, 'WARN', 'OK') AS status
FROM c
LEFT JOIN t ON t.db_key = c.db_key
ORDER BY IFF(COALESCE(t.tagged_columns, 0) = 0 AND c.total_columns >= :min_columns, 0, 1), c.total_columns DESC, c.database_name
