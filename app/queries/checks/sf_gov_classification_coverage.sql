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
WITH __INCLUDE_sf_gov_sensitive_columns__,
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
