-- query_id: sf_storage_clustering_value
-- title: Automatic clustering that may not pay
-- domain: storage   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_reads (default 100) reads: least a row needs before it can flag; :poor_scan_pct (default
--   50) poor scan pct: value this check uses; :recluster_ratio (default 2) recluster ratio: value this
--   check uses; :warn_usd (default 25) usd: at or above this the row reads WARN; :crit_usd (default
--   250) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a table that spent automatic clustering credits in the window. read_queries
--   counts queries that read it (ACCESS_HISTORY); avg_scan_pct is the share of partitions scanned by
--   queries that read only this table (low = clustering prunes well). recluster_ratio_x = bytes
--   reclustered over the table's active bytes (high = DML keeps undoing the clustering). usd_per_read
--   shows what each read costs in clustering upkeep.
-- healthy: status = OK when clustering costs under warn_usd, or the table is read at least min_reads
--   times with avg_scan_pct under poor_scan_pct and the table is not reclustered recluster_ratio x.
-- investigate_if: WARN when clustering costs warn_usd or more and the table is rarely read, prunes
--   poorly, or is reclustered recluster_ratio times its size; CRITICAL at crit_usd with those signs.
-- actions: 1) compare the clustering key with the filters of the top queries on the table (free); 2)
--   ALTER TABLE ... SUSPEND RECLUSTER, or change the key to a coarser expression such as a date
--   (config); 3) batch DML so fewer micro-partitions are rewritten, or drop the key (engineering).
-- next: none
-- caveats: avg_scan_pct uses single-table queries only; multi-table joins count in read_queries but not
--   in pruning. ACCESS_HISTORY needs Enterprise Edition (NOT_ASSESSED otherwise). Credits lag up to 3
--   hours.
WITH __INCLUDE_sf_storage_live_tables__,
__INCLUDE_sf_storage_table_use__,
ac AS (
  SELECT table_id, MAX(database_name || '.' || schema_name || '.' || table_name) AS table_fqn_hist,
         SUM(credits_used) AS credits, SUM(num_bytes_reclustered) AS bytes_reclustered,
         SUM(num_rows_reclustered) AS rows_reclustered
  FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
  HAVING SUM(credits_used) > 0
),
t AS (
  SELECT ac.*, COALESCE(lt.table_fqn, ac.table_fqn_hist) AS table_fqn, lt.clustering_key,
         lt.auto_clustering_on, lt.active_bytes, lt.row_count, lt.table_id IS NULL AS is_dropped,
         COALESCE(u.read_queries, 0) AS read_queries, u.last_read_at, u.single_table_queries,
         u.avg_scan_pct, u.single_table_hours,
         ac.bytes_reclustered / NULLIF(lt.active_bytes, 0) AS recluster_ratio_x,
         ac.credits * __CREDIT_PRICE__ AS usd
  FROM ac
  LEFT JOIN sf_storage_live_tables lt ON lt.table_id = ac.table_id
  LEFT JOIN sf_storage_table_use u ON u.table_id = ac.table_id
),
flagged AS (
  SELECT t.*,
         (read_queries < :min_reads
          OR COALESCE(avg_scan_pct, 0) >= :poor_scan_pct
          OR COALESCE(recluster_ratio_x, 0) >= :recluster_ratio) AS doubtful_value
  FROM t
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, f.table_id, clustering_key, auto_clustering_on, is_dropped, active_bytes, row_count,
       credits AS clustering_credits, bytes_reclustered, rows_reclustered,
       ROUND(recluster_ratio_x, 2) AS recluster_ratio_x,
       read_queries, last_read_at, single_table_queries, ROUND(avg_scan_pct, 1) AS avg_scan_pct,
       single_table_hours,
       usd AS est_clustering_usd_list,
       usd / NULLIF(read_queries, 0) AS usd_per_read,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(credits, 1) || ' clustering credits for ' || read_queries || ' reads'
         || COALESCE(', ' || ROUND(avg_scan_pct) || '% of partitions scanned', '') AS waste_reason,
       CASE WHEN a.access_rows = 0 THEN 'no_access_history'
            WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN a.access_rows = 0 OR __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd AND doubtful_value THEN 'CRITICAL'
         WHEN usd >= :warn_usd AND doubtful_value THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM flagged f CROSS JOIN sf_storage_access_seen a
ORDER BY credits DESC
