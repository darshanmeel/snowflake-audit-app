-- query_id: sf_storage_churn_unread
-- title: Tables that are rewritten often but never read
-- domain: storage   tier: standard
-- money: est_saving_usd_month
-- entity: tables = table_id
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (ACCESS_HISTORY)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_rows (default 1000000) rows: least changed rows a table needs before it can flag;
--   :crit_usd (default 100) usd a month: at or above this the row reads CRITICAL
-- empty_if: edition_too_low, view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. churn_gb is changed rows times the table's average row size, an
--   estimate; the compute that does the writes is not priced because no view splits it by table.
-- read_this: one row = one live table that had DML in the window and was not read by any query. rows_changed is rows
--   added, removed and updated; churn_gb estimates the data rewritten. time_travel_gb and failsafe_gb are the history
--   the rewrites left behind, and est_saving_usd_month is what that history costs a month: the most a shorter
--   retention or a TRANSIENT table would save.
-- healthy: status = OK when the table was read in the window, or changed few rows.
-- investigate_if: WARN when a table with >= min_rows changed rows had no read in the window; CRITICAL when its
--   history costs >= crit_usd a month. NOT_ASSESSED when ACCESS_HISTORY has no rows at all (edition or privilege).
-- actions: 1) ask the owner whether anything still needs the table (free); 2) stop the job that writes it, or lower
--   DATA_RETENTION_TIME_IN_DAYS / make it TRANSIENT if it can be rebuilt (config); 3) drop the table (spend: frees
--   storage and the writing compute)
-- next: sf_use_table_churn
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window, so reads cannot be told
-- caveats: a query that also writes the table (MERGE, UPDATE, DELETE, INSERT from itself) is not counted as a read. A table read only through a stream, dynamic table refresh, share or an external engine may show no read here.
--   ACCESS_HISTORY needs Enterprise Edition, lags up to 3 hours and holds successful queries only. TABLE_DML_HISTORY
--   lags up to 6 hours and leaves out hybrid tables. Storage bytes are point in time. The saving is a ceiling, and is
--   a monthly figure that is never added to a window cost.
WITH __INCLUDE_sf_storage_table_use__,
__INCLUDE_sf_storage_live_tables__,
wr AS (
  SELECT ah.query_id, f.value:objectId::NUMBER AS table_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.objects_modified) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
rd AS (
  SELECT r.table_id, COUNT(DISTINCT r.query_id) AS read_queries, MAX(r.query_start_time) AS last_read_at
  FROM sf_storage_reads r
  LEFT JOIN wr ON wr.query_id = r.query_id AND wr.table_id = r.table_id
  WHERE wr.query_id IS NULL
  GROUP BY r.table_id
),
d AS (
  SELECT table_id, SUM(COALESCE(rows_added, 0)) AS rows_added, SUM(COALESCE(rows_removed, 0)) AS rows_removed,
         SUM(COALESCE(rows_updated, 0)) AS rows_updated,
         COUNT(DISTINCT DATE(start_time)) AS active_days
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
),
s AS (
  SELECT t.database_name, t.schema_name, t.table_name, t.table_id, t.table_owner, t.is_transient, t.retention_time,
         t.row_count, t.active_bytes, t.time_travel_bytes, t.failsafe_bytes,
         d.rows_added + d.rows_removed + d.rows_updated AS rows_changed, d.active_days,
         COALESCE(u.read_queries, 0) AS read_queries, u.last_read_at,
         (d.rows_added + d.rows_removed + d.rows_updated) * t.active_bytes / NULLIF(t.row_count, 0) AS churn_bytes,
         (t.time_travel_bytes + t.failsafe_bytes) / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS history_usd
  FROM d
  JOIN sf_storage_live_tables t ON t.table_id = d.table_id
  LEFT JOIN rd u ON u.table_id = d.table_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name, table_name, table_id,
       table_owner, is_transient, retention_time, row_count, active_days, rows_changed, read_queries, last_read_at,
       churn_bytes / POWER(1024, 3) AS churn_gb, active_bytes / POWER(1024, 3) AS active_gb,
       time_travel_bytes / POWER(1024, 3) AS time_travel_gb, failsafe_bytes / POWER(1024, 3) AS failsafe_gb,
       IFF(read_queries = 0 AND rows_changed >= :min_rows, history_usd, NULL) AS est_saving_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(read_queries = 0 AND rows_changed >= :min_rows,
           rows_changed || ' rows changed and no query read the table', NULL) AS waste_reason,
       CASE WHEN a.access_rows = 0 THEN 'no_access_history' END AS not_assessed_reason,
       CASE
         WHEN a.access_rows = 0 THEN 'NOT_ASSESSED'
         WHEN read_queries > 0 OR rows_changed < :min_rows THEN 'OK'
         WHEN history_usd >= :crit_usd THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM s CROSS JOIN sf_storage_access_seen a
ORDER BY IFF(status IN ('WARN', 'CRITICAL'), 0, 1), est_saving_usd_month DESC NULLS LAST, rows_changed DESC
