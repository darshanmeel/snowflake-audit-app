-- query_id: sf_storage_clustering_candidates
-- title: Large tables that scan most partitions and have no clustering key
-- domain: storage   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (ACCESS_HISTORY)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :lookup_match_pct (default 5) percent of scanned rows a filter must match to look like a
--   point lookup; :min_table_gb (default 100) table gb: least a row needs before it can flag; :min_queries
--   (default 50) queries: least a row needs before it can flag; :poor_scan_pct (default 80) poor scan
--   pct: value this check uses; :warn_hours (default 5) hours: at or above this the row reads WARN;
--   :crit_hours (default 50) hours: at or above this the row reads CRITICAL
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a live table of at least min_table_gb with no clustering key, read by at least
--   min_queries single-table queries in the window. avg_scan_pct is the share of its partitions those
--   queries scanned (100 = no pruning at all); single_table_hours is their total elapsed time, the time
--   a good key could cut. top_column, second_column and third_column are the columns queries filter or
--   join on with the most query time, and suggestion says clustering, search_optimization (selective
--   point lookups on a table not yet search-optimized) or none. A candidate only: check the filter
--   columns before adding a key.
-- healthy: status = OK when queries prune well (avg_scan_pct under poor_scan_pct) or spend under
--   warn_hours on the table.
-- investigate_if: WARN when avg_scan_pct >= poor_scan_pct and the queries ran warn_hours or more;
--   CRITICAL at crit_hours.
-- actions: 1) look at the WHERE clauses of the slowest queries on the table; if they share a date or id
--   column, sort new loads by it (free); 2) ALTER TABLE ... CLUSTER BY (that column), then watch
--   sf_storage_clustering_value for its upkeep cost (config); 3) for point lookups on high-cardinality
--   columns consider search optimization instead (spend).
-- next: none
-- caveats: only queries reading exactly this one table are used for pruning; full scans that are
--   intended (e.g. rebuilds, exports) look the same. ACCESS_HISTORY needs Enterprise Edition
--   (NOT_ASSESSED otherwise). Queries lag up to 3 hours. Pruning views lag up to 4 hours, keep the 1,000
--   longest scans per query and skip hybrid tables; search optimization needs Enterprise edition. Only the
--   EQUALITY or SUBSTRING method Snowflake suggests is read, never its expression.
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
col AS (
  SELECT table_id, UPPER(column_name) AS column_name,
         SUM(num_queries) AS queries,
         SUM(aggregate_query_execution_time) AS exec_ms,
         SUM(partitions_scanned) AS partitions_scanned,
         SUM(partitions_pruned) AS partitions_pruned,
         SUM(rows_scanned) AS rows_scanned, SUM(rows_matched) AS rows_matched,
         MAX(IFF(TO_VARCHAR(search_optimization_supported_expressions) ILIKE '%EQUALITY%'
                 OR TO_VARCHAR(search_optimization_supported_expressions) ILIKE '%SUBSTRING%', 1, 0)) AS sos_supported
  FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__
    AND UPPER(access_type) IN ('WHERE', 'JOIN') AND column_name IS NOT NULL
  GROUP BY table_id, UPPER(column_name)
),
ranked AS (
  SELECT col.*, ROW_NUMBER() OVER (PARTITION BY table_id ORDER BY exec_ms DESC, column_name) AS rk
  FROM col
),
topc AS (
  SELECT table_id,
         MAX(IFF(rk = 1, column_name, NULL)) AS top_column,
         MAX(IFF(rk = 1, exec_ms, NULL)) AS top_exec_ms,
         MAX(IFF(rk = 1, queries, NULL)) AS top_queries,
         MAX(IFF(rk = 1, 100 * partitions_scanned / NULLIF(partitions_scanned + partitions_pruned, 0), NULL)) AS scanned_pct,
         MAX(IFF(rk = 1, 100 * rows_matched / NULLIF(rows_scanned, 0), NULL)) AS matched_pct,
         MAX(IFF(rk = 1, sos_supported, NULL)) AS top_sos_supported,
         MAX(IFF(rk = 2, column_name, NULL)) AS second_column,
         MAX(IFF(rk = 3, column_name, NULL)) AS third_column
  FROM ranked
  WHERE rk <= 3
  GROUP BY table_id
),
sos_now AS (
  -- BASE_TABLE_ID or TABLE_ID, whichever the view has while the rename rolls out.
  SELECT DISTINCT COALESCE(o:BASE_TABLE_ID, o:TABLE_ID)::NUMBER AS table_id
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o, start_time FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
t AS (
  SELECT lt.table_fqn, lt.table_id, lt.database_name, lt.schema_name, lt.table_name, lt.table_owner,
         lt.active_bytes, lt.row_count, lt.last_altered,
         lt.active_bytes / POWER(1024, 3) AS active_gb,
         u.read_queries, u.single_table_queries, u.avg_scan_pct, u.single_table_hours,
         u.single_table_bytes_scanned,
         p.top_column, p.second_column, p.third_column, p.top_exec_ms / 3600000 AS top_column_hours,
         p.top_queries AS top_column_queries, p.scanned_pct AS top_column_scanned_pct,
         CASE WHEN p.top_sos_supported = 1 AND COALESCE(p.matched_pct, 100) < :lookup_match_pct
                   AND s.table_id IS NULL THEN 'search_optimization'
              -- same measure as status, so an OK row never suggests a key
              WHEN COALESCE(u.avg_scan_pct, 0) >= :poor_scan_pct THEN 'clustering'
              ELSE 'none' END AS suggestion
  FROM sf_storage_live_tables lt
  JOIN sf_storage_table_use u ON u.table_id = lt.table_id
  LEFT JOIN topc p ON p.table_id = lt.table_id
  LEFT JOIN sos_now s ON s.table_id = lt.table_id
  WHERE lt.table_type = 'BASE TABLE' AND NOT lt.is_hybrid
    AND NULLIF(TRIM(lt.clustering_key), '') IS NULL
    AND lt.active_bytes >= :min_table_gb * POWER(1024, 3)
    AND u.single_table_queries >= :min_queries
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_id, database_name, schema_name, table_name, table_owner,
       active_bytes, active_gb, row_count, last_altered,
       read_queries, single_table_queries, ROUND(avg_scan_pct, 1) AS avg_scan_pct,
       single_table_hours, single_table_bytes_scanned,
       top_column, second_column, third_column, top_column_queries, ROUND(top_column_hours, 2) AS top_column_hours,
       ROUND(top_column_scanned_pct, 1) AS top_column_scanned_pct, suggestion,
       active_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS est_storage_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       single_table_queries || ' queries scanned ' || ROUND(avg_scan_pct) || '% of partitions for '
         || ROUND(single_table_hours, 1) || ' h' AS waste_reason,
       -- rows exist only where ACCESS_HISTORY has reads; without it the result is empty (empty_if)
       CASE WHEN avg_scan_pct IS NULL THEN 'no_partition_stats' END AS not_assessed_reason,
       CASE
         WHEN avg_scan_pct IS NULL THEN 'NOT_ASSESSED'
         WHEN avg_scan_pct >= :poor_scan_pct AND single_table_hours >= :crit_hours THEN 'CRITICAL'
         WHEN avg_scan_pct >= :poor_scan_pct AND single_table_hours >= :warn_hours THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY IFF(avg_scan_pct >= :poor_scan_pct, single_table_hours, 0) DESC NULLS LAST
