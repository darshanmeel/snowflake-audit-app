-- query_id: access_views_inventory
-- title: View inventory (lineage completeness and materialized views)
-- domain: governance_access   tier: standard
-- entity: views = view_catalog, view_schema, view_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.VIEWS, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :top_n (default 100000) row cap - current-state inventory, no window.
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one view (or materialized view) visible to your grants, with whether it is
--   materialized, updatable/insertable, its sql_path, and the size of its definition. Use it to
--   complete the lineage picture (views mediate table-to-table flows that table lineage may not
--   attribute) and to inventory materialized views (which carry compute + storage cost).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: live views, plus materialized views that only TABLES lists (no definition
--   there, so their definition_chars is NULL). sql_path has no Snowflake equivalent (NULL).
--   references_mask_or_filter is also TRUE when a masking or row access policy sits on the view.
WITH v AS (
  SELECT table_catalog, table_schema, table_name,
         IFF(view_definition ILIKE '%MATERIALIZED VIEW%', 'YES', 'NO') AS is_materialized,
         is_updatable, insertable_into, view_definition
  FROM SNOWFLAKE.ACCOUNT_USAGE.VIEWS
  WHERE deleted IS NULL
),
mv AS (
  SELECT t.table_catalog, t.table_schema, t.table_name, 'YES' AS is_materialized,
         'NO' AS is_updatable, 'NO' AS insertable_into, CAST(NULL AS VARCHAR) AS view_definition
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
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
