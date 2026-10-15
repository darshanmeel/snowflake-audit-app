-- query_id: access_column_masks_inventory
-- title: Column masks inventory
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a column in the account that has a column mask attached. The columns that
--   matter are mask_name (which masking function) and using_columns (what it reads to decide the
--   mask).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: masking policies on columns (direct or through a tag); mask_name = policy
--   database.schema.name, using_columns = ref_arg_column_names (conditional masking arguments);
--   attachment = 'tag' when the mask reaches the column through a tag (tag_name = tag
--   database.schema.name), else 'direct'.
SELECT 0 AS window_days, ref_database_name AS table_catalog, ref_schema_name AS table_schema,
       ref_entity_name AS table_name, ref_column_name AS column_name,
       policy_db || '.' || policy_schema || '.' || policy_name AS mask_name,
       TO_VARCHAR(ref_arg_column_names) AS using_columns,
       IFF(pr.tag_name IS NOT NULL, 'tag', 'direct') AS attachment,
       IFF(pr.tag_name IS NOT NULL, pr.tag_database || '.' || pr.tag_schema || '.' || pr.tag_name, NULL) AS tag_name
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES pr
WHERE policy_kind = 'MASKING_POLICY'
  AND ref_column_name IS NOT NULL
ORDER BY table_catalog, table_schema, table_name, column_name
