-- query_id: access_column_masks_inventory
-- shims: POLICY_REFERENCES
-- reads: INFORMATION_SCHEMA table functions POLICY_REFERENCES (table function, per policy)
-- fallback_note: masking, row access, projection and aggregation policies only; the name stands in for the policy id
SELECT 0 AS window_days, ref_database_name AS table_catalog, ref_schema_name AS table_schema,
       ref_entity_name AS table_name, ref_column_name AS column_name,
       policy_db || '.' || policy_schema || '.' || policy_name AS mask_name,
       TO_VARCHAR(ref_arg_column_names) AS using_columns,
       IFF(pr.tag_name IS NOT NULL, 'tag', 'direct') AS attachment,
       IFF(pr.tag_name IS NOT NULL, pr.tag_database || '.' || pr.tag_schema || '.' || pr.tag_name, NULL) AS tag_name
FROM __SHIM_POLICY_REFERENCES__ pr
WHERE policy_kind = 'MASKING_POLICY'
  AND ref_column_name IS NOT NULL
ORDER BY table_catalog, table_schema, table_name, column_name
