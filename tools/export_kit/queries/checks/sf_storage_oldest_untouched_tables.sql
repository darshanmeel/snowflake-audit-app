-- query_id: sf_storage_oldest_untouched_tables
-- title: Tables nothing has changed for the longest
-- domain: storage   tier: standard
-- entity: tables = table_id
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :stale_days (default 365) days: a table unchanged this long or longer can flag; :min_gb (default 1)
--   gb: least a row needs before it can flag; :top_n (default 200) row cap: the oldest tables kept
--   besides the flagged ones
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a live table, oldest last_altered first. days_since_altered counts from the last
--   DML, DDL or background change; total_gb counts active, Time Travel, Fail-safe and clone-retained bytes.
--   est_storage_usd_month is what the table costs to keep a month, not a saving.
-- healthy: status = OK when the table changed within stale_days, or holds less than min_gb.
-- investigate_if: WARN when a table of min_gb or more has not changed for stale_days.
-- actions: 1) check sf_storage_unused_tables to see whether anything still reads it, and ask the owner
--   (free); 2) make it TRANSIENT or lower its retention if it is a frozen copy (config); 3) unload it to
--   cheaper storage and drop it (engineering).
-- next: sf_storage_unused_tables
-- caveats: last_altered also moves on background metadata maintenance, so a table can look newer than its
--   data. A table with no TABLES row has NULL last_altered, reads NOT_ASSESSED and sorts last. The cap
--   keeps every flagged table plus the top_n oldest. Dropped and Fail-safe tables are
--   left out, as are the tables in Snowflake's own SNOWFLAKE database. Storage bytes are point in time. TABLES lags up to 90 minutes.
WITH -- Live tables with their current storage split: TABLE_STORAGE_METRICS holds the bytes, TABLES the
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
),
t AS (
  SELECT lt.*,
         -- same naming as table_inventory_type: TABLES reports dynamic and hybrid tables as BASE TABLE
         IFF(lt.is_dynamic, 'DYNAMIC TABLE', IFF(lt.is_hybrid, 'HYBRID TABLE', lt.table_type)) AS table_kind,
         -- a change after the as-of date reads 0, not negative
         GREATEST(DATEDIFF(day, lt.last_altered, __AS_OF_DATE__), 0) AS days_since_altered,
         lt.total_bytes / POWER(1024, 3) AS total_gb,
         (lt.active_bytes + lt.time_travel_bytes + lt.failsafe_bytes) / POWER(1024, 4)
           * __STORAGE_PRICE_TB_MONTH__ AS usd
  FROM sf_storage_live_tables lt
  -- Snowflake's own database (Trust Center state and the like) is not the customer's to clean up
  WHERE COALESCE(lt.database_name, '') <> 'SNOWFLAKE'
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_id, database_name, database_id, schema_name, schema_id, table_name, table_owner,
       table_kind AS table_type, is_transient, row_count, created, last_altered, days_since_altered,
       active_bytes, time_travel_bytes, failsafe_bytes, total_gb,
       usd AS est_storage_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(last_altered IS NULL, 'no_tables_row', NULL) AS not_assessed_reason,
       CASE
         WHEN last_altered IS NULL THEN 'NOT_ASSESSED'
         WHEN days_since_altered >= :stale_days AND total_gb >= :min_gb THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
-- flagged tables always stay, so the cap never hides one behind small old tables
QUALIFY (days_since_altered >= :stale_days AND total_gb >= :min_gb)
     OR ROW_NUMBER() OVER (ORDER BY last_altered ASC NULLS LAST, total_bytes DESC, table_id) <= :top_n
ORDER BY last_altered ASC NULLS LAST, total_bytes DESC
