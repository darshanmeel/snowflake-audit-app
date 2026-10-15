-- query_id: sf_gov_classification_coverage
-- title: Columns classification found sensitive but left untagged or unmasked
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATA_CLASSIFICATION_LATEST, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one column that the latest Snowflake classification of its table recommended as
--   IDENTIFIER, QUASI_IDENTIFIER or SENSITIVE. is_tagged is TRUE when the column carries the matching
--   system or a custom sensitive tag; is_masked when a masking policy reaches it.
-- healthy: status = OK when the column is tagged and masked.
-- investigate_if: WARN when the recommendation was never applied as a tag, or a QUASI_IDENTIFIER /
--   SENSITIVE column has no masking; CRITICAL when an IDENTIFIER column has no masking policy.
-- actions: 1) apply the recommendations (SYSTEM$CLASSIFY with auto_tag, or accept them in Snowsight)
--   (free); 2) put masking policies on the classification tags so tagged columns are masked (config);
--   3) schedule automatic classification on the databases that hold customer data (config)
-- next: none
-- caveats: optional: DATA_CLASSIFICATION_LATEST exists only on accounts using classification
--   (Enterprise); without it this check fails and nothing else is affected. RESULT is read as column ->
--   recommendation.{privacy_category, semantic_category, confidence}; tables never classified are not
--   listed. Tag-based masking through a tag the column does not carry is not seen.
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
cls AS (
  SELECT UPPER(o:DATABASE_NAME::VARCHAR) AS database_name, UPPER(o:SCHEMA_NAME::VARCHAR) AS schema_name,
         UPPER(o:TABLE_NAME::VARCHAR) AS table_name, o:TABLE_ID::VARCHAR AS table_id,
         TRY_TO_TIMESTAMP_LTZ(TO_VARCHAR(o:LAST_CLASSIFIED_ON)) AS last_classified_on,
         o:STATUS::VARCHAR AS classification_status, o:RESULT AS result
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_CLASSIFICATION_LATEST)
),
cols AS (
  SELECT c.database_name, c.schema_name, c.table_name, c.table_id, c.last_classified_on, c.classification_status,
         UPPER(f.key) AS column_name,
         UPPER(f.value:recommendation:privacy_category::VARCHAR) AS rec_privacy_category,
         UPPER(f.value:recommendation:semantic_category::VARCHAR) AS rec_semantic_category,
         UPPER(f.value:recommendation:confidence::VARCHAR) AS confidence
  FROM cls c, LATERAL FLATTEN(input => COALESCE(c.result:classification_result, c.result)) f
  WHERE f.value:recommendation:privacy_category IS NOT NULL
    AND UPPER(f.value:recommendation:privacy_category::VARCHAR) <> 'INSENSITIVE'
),
direct_mask AS (
  SELECT ref_database_name, ref_schema_name, ref_entity_name, ref_column_name, LISTAGG(DISTINCT policy_fqn, ', ') AS policies
  FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND ref_column_name IS NOT NULL
  GROUP BY 1, 2, 3, 4
),
j AS (
  SELECT c.*, s.column_name IS NOT NULL AS is_tagged, s.privacy_category AS tagged_privacy_category,
         COALESCE(s.masking_policies, d.policies) AS masking_policies
  FROM cols c
  LEFT JOIN sf_gov_sensitive_columns s ON s.database_name = c.database_name AND s.schema_name = c.schema_name
     AND s.table_name = c.table_name AND s.column_name = c.column_name
  LEFT JOIN direct_mask d ON d.ref_database_name = c.database_name AND d.ref_schema_name = c.schema_name
     AND d.ref_entity_name = c.table_name AND d.ref_column_name = c.column_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name, table_name, table_id,
       column_name, database_name || '.' || schema_name || '.' || table_name AS table_fqn,
       rec_privacy_category, rec_semantic_category, confidence, is_tagged, tagged_privacy_category,
       masking_policies IS NOT NULL AS is_masked, masking_policies, last_classified_on, classification_status,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         'classified ' || rec_privacy_category || COALESCE(' / ' || rec_semantic_category, ''),
         IFF(NOT is_tagged, 'recommendation not applied as a tag', NULL),
         IFF(masking_policies IS NULL, 'no masking policy', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN masking_policies IS NULL AND rec_privacy_category = 'IDENTIFIER' THEN 'CRITICAL'
         WHEN masking_policies IS NULL OR NOT is_tagged THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, table_fqn, column_name
