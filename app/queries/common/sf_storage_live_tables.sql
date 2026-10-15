-- Live tables with their current storage split: TABLE_STORAGE_METRICS holds the bytes, TABLES the
-- settings. The YES/NO text flags are turned into booleans so every storage check reads them alike.
sf_storage_live_tables AS (
  SELECT m.id AS table_id, m.table_catalog AS database_name, m.table_catalog_id AS database_id,
         m.table_schema AS schema_name, m.table_schema_id AS schema_id, m.table_name,
         m.table_catalog || '.' || m.table_schema || '.' || m.table_name AS table_fqn,
         m.clone_group_id,
         COALESCE(m.active_bytes, 0) AS active_bytes,
         COALESCE(m.time_travel_bytes, 0) AS time_travel_bytes,
         COALESCE(m.failsafe_bytes, 0) AS failsafe_bytes,
         COALESCE(m.retained_for_clone_bytes, 0) AS retained_for_clone_bytes,
         COALESCE(m.active_bytes, 0) + COALESCE(m.time_travel_bytes, 0) + COALESCE(m.failsafe_bytes, 0)
           + COALESCE(m.retained_for_clone_bytes, 0) AS total_bytes,
         -- no TABLES row would make this NULL and drop the table from NOT is_transient filters
         COALESCE(m.is_transient = 'YES' OR t.is_transient = 'YES', m.is_transient = 'YES', FALSE) AS is_transient,
         COALESCE(t.table_type, 'BASE TABLE') AS table_type,
         t.retention_time, t.clustering_key,
         COALESCE(t.auto_clustering_on = 'YES', FALSE) AS auto_clustering_on,
         COALESCE(t.is_iceberg = 'YES', FALSE) AS is_iceberg,
         COALESCE(t.is_dynamic = 'YES', FALSE) AS is_dynamic,
         COALESCE(t.is_hybrid = 'YES', FALSE) AS is_hybrid,
         t.row_count, t.bytes AS table_bytes, t.table_owner, t.created, t.last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS m
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t ON t.table_id = m.id AND t.deleted IS NULL
  -- Fail-safe rows have NULL names (and can carry deleted = FALSE): they are not live tables.
  WHERE NOT COALESCE(m.deleted, FALSE) AND m.table_dropped IS NULL
    AND m.schema_dropped IS NULL AND m.catalog_dropped IS NULL
    AND m.table_name IS NOT NULL AND m.table_entered_failsafe IS NULL
)
