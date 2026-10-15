-- query_id: sf_use_table_churn
-- title: Write-heavy tables where Time Travel and Fail-safe grow
-- domain: storage   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_rows (default 100000) rows: least a row needs before it can flag; :warn_churn_x (default
--   0.5) churn x: at or above this the row reads WARN; :warn_usd (default 25) usd: at or above this the
--   row reads WARN; :crit_usd (default 250) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live table with DML in the window. rows_added / rows_removed / rows_updated
--   are summed from TABLE_DML_HISTORY; churn_x_per_day = (removed + updated) per day divided by the
--   table's current row_count, so 1.0 means the whole table is rewritten every day. Every rewritten
--   micro-partition is kept for retention_time days of Time Travel plus 7 days of Fail-safe, which is
--   what est_history_usd_month prices (time_travel_bytes + failsafe_bytes).
-- healthy: status = OK when the table is small, rewrites little of itself, or its history is cheap.
-- investigate_if: WARN when churn_x_per_day >= warn_churn_x on a table of >= min_rows rows whose Time
--   Travel + Fail-safe costs >= warn_usd a month; CRITICAL when that history costs >= crit_usd.
-- actions: 1) find the job behind the writes (full reload, MERGE on all rows, TRUNCATE+INSERT) (free);
--   2) lower DATA_RETENTION_TIME_IN_DAYS, or make a rebuildable table TRANSIENT to drop Fail-safe
--   (config); 3) switch the load to incremental or append-only, or cluster so MERGE touches fewer
--   partitions (engineering).
-- next: none
-- caveats: TABLE_DML_HISTORY is a newer view (lags up to 6 hours; some DML such as on hybrid tables is
--   not covered); if it is missing in the account the check fails. row_count is current, not average.
--   Storage bytes are point in time.
WITH d AS (
  SELECT table_id, SUM(COALESCE(rows_added, 0)) AS rows_added, SUM(COALESCE(rows_removed, 0)) AS rows_removed,
         SUM(COALESCE(rows_updated, 0)) AS rows_updated,
         COUNT(DISTINCT DATE(start_time)) AS active_days
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
),
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
),
s AS (
  SELECT t.database_name, t.schema_name, t.table_name, t.table_id, t.table_owner, t.is_transient,
         t.retention_time, t.row_count, t.active_bytes, t.time_travel_bytes, t.failsafe_bytes,
         d.rows_added, d.rows_removed, d.rows_updated, d.active_days,
         (d.rows_removed + d.rows_updated) / :period_days / NULLIF(t.row_count, 0) AS churn_x_per_day,
         (t.time_travel_bytes + t.failsafe_bytes) / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS history_usd,
         100 * (t.time_travel_bytes + t.failsafe_bytes) / NULLIF(t.active_bytes, 0) AS history_to_active_pct
  FROM d
  JOIN sf_storage_live_tables t ON t.table_id = d.table_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name,
       table_name, table_id, table_owner, is_transient, retention_time, row_count, active_days,
       rows_added, rows_removed, rows_updated, churn_x_per_day,
       active_bytes / POWER(1024, 3) AS active_gb,
       time_travel_bytes / POWER(1024, 3) AS time_travel_gb,
       failsafe_bytes / POWER(1024, 3) AS failsafe_gb, history_to_active_pct,
       history_usd AS est_history_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN COALESCE(row_count, 0) < :min_rows OR COALESCE(churn_x_per_day, 0) < :warn_churn_x THEN 'OK'
         WHEN history_usd >= :crit_usd THEN 'CRITICAL'
         WHEN history_usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY est_history_usd_month DESC NULLS LAST, churn_x_per_day DESC NULLS LAST
