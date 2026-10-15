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
)
