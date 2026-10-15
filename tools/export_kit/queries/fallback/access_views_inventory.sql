-- query_id: access_views_inventory
-- shims: VIEWS, TABLES, POLICY_REFERENCES
-- reads: INFORMATION_SCHEMA table functions VIEWS (view, per database), TABLES (view, POLICY_REFERENCES (table function, per policy)
-- fallback_note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; masking, row access, projection and aggregation policies only; the name stands in for the policy id
WITH v AS (
  SELECT table_catalog, table_schema, table_name,
         IFF(view_definition ILIKE '%MATERIALIZED VIEW%', 'YES', 'NO') AS is_materialized,
         is_updatable, insertable_into, view_definition
  FROM __SHIM_VIEWS__
  WHERE deleted IS NULL
),
mv AS (
  SELECT t.table_catalog, t.table_schema, t.table_name, 'YES' AS is_materialized,
         'NO' AS is_updatable, 'NO' AS insertable_into, CAST(NULL AS VARCHAR) AS view_definition
  FROM __SHIM_TABLES__ t
  LEFT JOIN v
    ON v.table_catalog = t.table_catalog AND v.table_schema = t.table_schema AND v.table_name = t.table_name
  WHERE t.deleted IS NULL AND t.table_type = 'MATERIALIZED VIEW' AND v.table_name IS NULL
),
all_views AS (
  SELECT * FROM v
  UNION ALL
  SELECT * FROM mv
),
view_policies AS (
  SELECT DISTINCT ref_database_name, ref_schema_name, ref_entity_name
  FROM __SHIM_POLICY_REFERENCES__
  WHERE policy_kind IN ('MASKING_POLICY', 'ROW_ACCESS_POLICY')
)
SELECT 0 AS window_days, a.table_catalog AS view_catalog, a.table_schema AS view_schema,
       a.table_name AS view_name, a.is_materialized, a.is_updatable,
       a.insertable_into AS is_insertable_into,
       CAST(NULL AS VARCHAR) AS sql_path,
       LENGTH(a.view_definition) AS definition_chars,
       (COALESCE(UPPER(a.view_definition) LIKE '%MASK%' OR UPPER(a.view_definition) LIKE '%FILTER%', FALSE)
         OR p.ref_entity_name IS NOT NULL) AS references_mask_or_filter
FROM all_views a
LEFT JOIN view_policies p
  ON p.ref_database_name = a.table_catalog AND p.ref_schema_name = a.table_schema
 AND p.ref_entity_name = a.table_name
QUALIFY ROW_NUMBER() OVER (ORDER BY a.table_catalog, a.table_schema, a.table_name) <= :top_n
ORDER BY view_catalog, view_schema, view_name
