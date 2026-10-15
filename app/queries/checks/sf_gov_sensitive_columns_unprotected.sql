-- query_id: sf_gov_sensitive_columns_unprotected
-- title: Sensitive columns with no masking policy
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live column tagged sensitive: Snowflake classification tags
--   (PRIVACY_CATEGORY = IDENTIFIER / QUASI_IDENTIFIER / SENSITIVE, SEMANTIC_CATEGORY = EMAIL, NAME ...)
--   or a custom tag whose name says PII, sensitive, confidential, PHI, PCI, GDPR, personal or
--   restricted. masked_via says how a masking policy reaches it (column policy, or a tag on the column
--   / table / schema / database).
-- healthy: status = OK when a masking policy covers the column.
-- investigate_if: WARN when a sensitive column has no masking policy (a row access policy alone does
--   not hide the value); CRITICAL when that column is an IDENTIFIER (direct identifier such as email,
--   name, national id) or carries a custom PII / PHI / PCI tag.
-- actions: 1) attach a masking policy to the tag (tag-based masking) so every tagged column is covered
--   at once (config); 2) for one-off columns ALTER TABLE ... MODIFY COLUMN ... SET MASKING POLICY
--   (config); 3) run classification on new schemas so new PII gets tagged (config)
-- next: none
-- caveats: only columns that are tagged are seen; untagged PII is invisible here (see
--   sf_gov_classification_coverage). Masking policies and tag-based masking need Enterprise edition.
--   POLICY_REFERENCES and TAG_REFERENCES lag up to 2 hours; a policy's body is not inspected, so a
--   policy that returns the value to everyone still counts as covered. Only ACTIVE policy attachments count
--   (POLICY_REFERENCES.POLICY_STATUS).
WITH __INCLUDE_sf_gov_sensitive_columns__
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name, table_name, column_name,
       database_name || '.' || schema_name || '.' || table_name AS table_fqn,
       privacy_category, semantic_category, custom_tags, masking_policies, masked_via, row_access_policies,
       masking_policies IS NOT NULL AS is_masked,
       IFF(masking_policies IS NOT NULL, NULL, ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         'no masking policy',
         IFF(privacy_category IS NOT NULL, 'privacy category ' || privacy_category, NULL),
         IFF(semantic_category IS NOT NULL, 'semantic category ' || semantic_category, NULL),
         IFF(custom_tags IS NOT NULL AND custom_tags <> '', 'tagged ' || custom_tags, NULL),
         IFF(row_access_policies IS NOT NULL, 'row access policy only', NULL)), '; ')) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN masking_policies IS NOT NULL THEN 'OK'
         WHEN privacy_category = 'IDENTIFIER'
              OR has_pii_tag THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM sf_gov_sensitive_columns
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, table_fqn, column_name
