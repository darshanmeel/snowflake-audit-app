-- query_id: access_row_filters_inventory
-- title: Row filters inventory
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a table or view in the account that has a row-level access filter attached.
--   The columns that matter are filter_name (which filter function) and target_columns (what it
--   evaluates to decide row visibility).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: row access policies on tables and views; filter_name = policy
--   database.schema.name, target_columns = ref_arg_column_names.
SELECT 0 AS window_days, ref_database_name AS table_catalog, ref_schema_name AS table_schema,
       ref_entity_name AS table_name,
       policy_db || '.' || policy_schema || '.' || policy_name AS filter_name,
       TO_VARCHAR(ref_arg_column_names) AS target_columns
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE policy_kind = 'ROW_ACCESS_POLICY'
ORDER BY table_catalog, table_schema, table_name
