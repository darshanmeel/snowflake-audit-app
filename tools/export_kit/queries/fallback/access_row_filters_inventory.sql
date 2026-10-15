-- query_id: access_row_filters_inventory
-- shims: POLICY_REFERENCES
-- reads: INFORMATION_SCHEMA table functions POLICY_REFERENCES (table function, per policy)
-- fallback_note: masking, row access, projection and aggregation policies only; the name stands in for the policy id
SELECT 0 AS window_days, ref_database_name AS table_catalog, ref_schema_name AS table_schema,
       ref_entity_name AS table_name,
       policy_db || '.' || policy_schema || '.' || policy_name AS filter_name,
       TO_VARCHAR(ref_arg_column_names) AS target_columns
FROM __SHIM_POLICY_REFERENCES__
WHERE policy_kind = 'ROW_ACCESS_POLICY'
ORDER BY table_catalog, table_schema, table_name
