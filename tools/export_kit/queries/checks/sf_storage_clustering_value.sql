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
-- How each table was read over the window: ACCESS_HISTORY names the base tables a query touched,
-- QUERY_HISTORY its partitions. Pruning is judged only on queries that read exactly one table,
-- because QUERY_HISTORY partition counts cannot be split between the tables of a join.
sf_storage_reads AS (
  SELECT ah.query_id, ah.query_start_time, f.value:objectId::NUMBER AS table_id,
         COUNT(*) OVER (PARTITION BY ah.query_id) AS tables_in_query
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.base_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
    AND f.value:objectDomain::STRING = 'Table'
),
sf_storage_access_seen AS (
  SELECT COUNT(*) AS access_rows FROM sf_storage_reads
),
sf_storage_table_use AS (
  SELECT r.table_id,
         COUNT(DISTINCT r.query_id) AS read_queries,
         MAX(r.query_start_time) AS last_read_at,
         COUNT(DISTINCT IFF(r.tables_in_query = 1 AND q.partitions_total > 0, r.query_id, NULL))
           AS single_table_queries,
         AVG(IFF(r.tables_in_query = 1 AND q.partitions_total > 0,
                 100 * q.partitions_scanned / q.partitions_total, NULL)) AS avg_scan_pct,
         SUM(IFF(r.tables_in_query = 1, q.total_elapsed_time, 0)) / 3600000 AS single_table_hours,
         SUM(IFF(r.tables_in_query = 1, q.bytes_scanned, 0)) AS single_table_bytes_scanned
  FROM sf_storage_reads r
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    ON q.query_id = r.query_id
   AND q.start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__)
   AND q.start_time < __AS_OF_DATE__
  GROUP BY r.table_id
),
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
