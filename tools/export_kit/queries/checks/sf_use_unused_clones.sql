-- query_id: sf_use_unused_clones
-- title: Zero-copy clones nobody reads
-- domain: storage   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :idle_days (default 30) idle days: value this check uses; :old_clone_days (default 90) old
--   clone days: value this check uses; :warn_usd (default 5) usd: at or above this the row reads WARN;
--   :crit_usd (default 50) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live table created by CLONE (its clone_group_id differs from its own id)
--   that is older than idle_days and that no query read, directly or through a view, in the last
--   idle_days. own_bytes are the bytes the clone no longer shares with its source (rows changed since
--   the clone, plus their Time Travel and Fail-safe): a fresh clone costs nothing and grows as it or
--   its source is rewritten. source_table is the oldest ancestor of the clone group; still_written =
--   TRUE when the clone itself was changed within idle_days.
--   est_saving_usd_month is the same figure on flagged rows: what removing it saves each month.
-- healthy: status = OK when an unread clone is young and owns almost no bytes.
-- investigate_if: WARN when an unread clone owns >= warn_usd a month of bytes, or is older than
--   old_clone_days; CRITICAL when it owns >= crit_usd a month. NOT_ASSESSED when ACCESS_HISTORY is
--   empty.
-- actions: 1) ask the owner whether the dev/test/backup copy is still needed (free); 2) drop it, or
--   keep backup clones on a dated rotation and dev clones re-cloned on demand (config); 3) clone
--   schemas or databases per branch in CI and drop them when the branch closes (engineering).
-- next: none
-- caveats: ACCESS_HISTORY needs Enterprise edition and lags up to 3 hours; reads through data sharing
--   are not in it. Clones made from a clone share the group's oldest ancestor as source_table. Dropping
--   a clone can also release bytes its source kept for it (see sf_storage_clone_retained_bytes).
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
reads AS (
  SELECT f.value:"objectId"::NUMBER AS table_id, MAX(ah.query_start_time) AS last_read_at
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT()))) f
  WHERE ah.query_start_time >= DATEADD(day, -:idle_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
  GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM reads
),
src AS (
  SELECT id AS table_id,
         -- a source in Fail-safe has NULL names and can carry deleted = FALSE
         COALESCE(table_catalog || '.' || table_schema || '.' || table_name, 'Fail-safe table (' || id || ')')
           AS table_fqn,
         (COALESCE(deleted, FALSE) OR table_dropped IS NOT NULL OR table_entered_failsafe IS NOT NULL
          OR table_name IS NULL) AS is_dropped
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
),
c AS (
  SELECT t.*, s.table_fqn AS source_table, s.is_dropped AS source_dropped,
         t.active_bytes + t.time_travel_bytes + t.failsafe_bytes AS own_bytes,
         DATEDIFF(day, t.created, __AS_OF_DATE__) AS clone_age_days,
         t.last_altered >= DATEADD(day, -:idle_days, __AS_OF_DATE__) AS still_written,
         (t.active_bytes + t.time_travel_bytes + t.failsafe_bytes) / POWER(1024, 4)
           * __STORAGE_PRICE_TB_MONTH__ AS own_usd,
         COUNT(*) OVER (PARTITION BY t.clone_group_id) AS live_clones_in_group
  FROM sf_storage_live_tables t
  LEFT JOIN src s ON s.table_id = t.clone_group_id
  WHERE t.clone_group_id IS NOT NULL AND t.clone_group_id <> t.table_id
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, c.database_name, c.schema_name, c.table_name,
       c.table_id, c.table_fqn, c.table_owner, c.table_type, c.is_transient, c.created, c.clone_age_days,
       c.last_altered, c.still_written, c.source_table, c.clone_group_id, c.source_dropped,
       c.live_clones_in_group, c.row_count, c.own_bytes / POWER(1024, 3) AS own_gb,
       c.retained_for_clone_bytes / POWER(1024, 3) AS retained_for_clone_gb,
       c.own_usd AS est_storage_usd_month, c.own_usd AS est_saving_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN seen.access_rows = 0 THEN 'access_history_empty_or_not_enterprise'
            WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN seen.access_rows = 0 OR __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN c.own_usd >= :crit_usd THEN 'CRITICAL'
         WHEN c.own_usd >= :warn_usd OR c.clone_age_days >= :old_clone_days THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM c
CROSS JOIN seen
LEFT JOIN reads r ON r.table_id = c.table_id
WHERE r.table_id IS NULL
  AND c.created < DATEADD(day, -:idle_days, __AS_OF_DATE__)
ORDER BY est_storage_usd_month DESC NULLS LAST, clone_age_days DESC
