-- query_id: table_inventory_type
-- shims: TABLES
-- reads: INFORMATION_SCHEMA table functions TABLES (view, per database)
-- fallback_note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
SELECT 0 AS window_days, table_catalog, table_schema,
       IFF(is_dynamic = 'YES', 'DYNAMIC TABLE', IFF(is_hybrid = 'YES', 'HYBRID TABLE', table_type)) AS table_type,
       CASE
         WHEN table_type IN ('VIEW', 'MATERIALIZED VIEW') THEN NULL
         WHEN is_iceberg = 'YES' THEN 'ICEBERG'
         WHEN table_type = 'EXTERNAL TABLE' THEN 'EXTERNAL'
         ELSE 'SNOWFLAKE'
       END AS data_source_format,
       COUNT(*) AS table_count,
       SUM(IFF(table_type = 'VIEW', NULL, bytes)) AS table_bytes
FROM __SHIM_TABLES__
WHERE deleted IS NULL
GROUP BY 2, 3, 4, 5
ORDER BY 2, 3, 4
