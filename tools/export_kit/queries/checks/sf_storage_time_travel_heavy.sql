-- query_id: sf_storage_time_travel_heavy
-- title: Tables paying for a lot of Time Travel
-- domain: storage   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :min_tt_gb (default 10) tt gb: least a row needs before it can flag; :warn_tt_pct (default
--   50) tt pct: at or above this the row reads WARN; :warn_usd (default 25) usd: at or above this the
--   row reads WARN; :crit_usd (default 250) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a live table that holds Time Travel bytes today. tt_to_active_pct compares the
--   old row versions kept for undo/AT queries with the live data; a high share on a table with a long
--   retention_time means a churny table (MERGE, full rewrite, TRUNCATE+INSERT) kept for many days.
--   est_saving_usd_month_if_1_day assumes Time Travel bytes shrink in proportion to retention days.
-- healthy: status = OK when Time Travel costs less than warn_usd a month and is under warn_tt_pct of
--   the table's active bytes (or the table already keeps 1 day or less).
-- investigate_if: on a table keeping more than 1 day, WARN when Time Travel costs warn_usd or more a
--   month, or is at least min_tt_gb and warn_tt_pct of active bytes; CRITICAL at crit_usd a month.
-- actions: 1) check whether anyone restores or queries AT/BEFORE on this table (free); 2) lower it with
--   ALTER TABLE ... SET DATA_RETENTION_TIME_IN_DAYS = 1 (or 0 for rebuildable tables), or set it on the
--   schema/database (config); 3) load incrementally instead of rewriting the whole table so fewer
--   versions are kept (engineering).
-- next: none
-- caveats: TABLE_STORAGE_METRICS lags up to 90 minutes and is a point-in-time value. Failsafe (7 more
--   days, not configurable) is shown but not counted as saving. Retention inherited from the schema or
--   database shows as the table's effective retention_time.
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
         100 * time_travel_bytes / NULLIF(active_bytes, 0) AS tt_to_active_pct,
         time_travel_bytes / POWER(1024, 3) AS tt_gb,
         time_travel_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS tt_usd
  FROM sf_storage_live_tables lt
  WHERE time_travel_bytes > 0
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_id, database_id, database_name, schema_name, table_name, table_type, is_transient,
       retention_time AS retention_days, row_count, last_altered,
       active_bytes, time_travel_bytes, failsafe_bytes, tt_gb,
       ROUND(tt_to_active_pct, 1) AS tt_to_active_pct,
       tt_usd AS est_storage_usd_month,
       failsafe_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS est_failsafe_usd_month,
       IFF(retention_time > 1, tt_usd * (1 - 1 / retention_time), 0) AS est_saving_usd_month_if_1_day,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(tt_gb, 1) || ' GB of Time Travel (' || COALESCE(ROUND(tt_to_active_pct) || '% of active', 'no active bytes')
         || ') kept ' || COALESCE(retention_time::STRING, '?') || ' days' AS waste_reason,
       CASE WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         -- already at 1 day: nothing to shorten, the 1-day saving is 0
         WHEN COALESCE(retention_time, 1) <= 1 THEN 'OK'
         WHEN tt_usd >= :crit_usd THEN 'CRITICAL'
         WHEN tt_usd >= :warn_usd THEN 'WARN'
         WHEN tt_gb >= :min_tt_gb AND COALESCE(tt_to_active_pct, 100) >= :warn_tt_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY time_travel_bytes DESC
