-- query_id: table_inventory_type
-- title: Table and view inventory by type and format
-- domain: storage   tier: deep
-- entity: table groups = table_catalog, table_schema, table_type
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a database + schema + table_type + data_source_format combination, with the
--   count of tables and views matching it. table_type tells you base table vs external vs view vs
--   dynamic vs hybrid table; data_source_format is SNOWFLAKE (native), ICEBERG or EXTERNAL (files in a
--   stage), NULL for views. table_bytes sums the tables' active bytes (TABLES.BYTES), NULL for views.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: live tables and views per database and schema. table_type is Snowflake's
--   (a dynamic table reads DYNAMIC TABLE, a hybrid table HYBRID TABLE); data_source_format = ICEBERG, EXTERNAL (files in a stage) or
--   SNOWFLAKE (native), NULL for views. table_bytes leaves out Time Travel and Fail-safe bytes.
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
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE deleted IS NULL
GROUP BY 2, 3, 4, 5
ORDER BY 2, 3, 4
