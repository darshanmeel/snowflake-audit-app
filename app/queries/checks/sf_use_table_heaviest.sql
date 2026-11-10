-- query_id: sf_use_table_heaviest
-- title: Heaviest tables: the most query time, partitions read, full scans and spill
-- domain: performance   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 50) tables kept per ranking; :min_partitions (default 1000) partitions: least a
--   statement shape reads per run on a table before its scan can count as full, as in sf_query_full_scans;
--   :scan_pct (default 80) pct: least share of the table's partitions a shape scans to count as full
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table that ranks in the top_n by at least one measure. queries and exec_s are
--   sums from TABLE_QUERY_PRUNING_HISTORY: the execution time of the queries that read the table.
--   partitions_scanned and rows_scanned are the table's own. full_scan_queries counts runs of statement
--   shapes that read at least min_partitions of the table per run and at least scan_pct of its partitions
--   over the window. spilled_gb is local plus remote spill of the queries that read the table, from
--   QUERY_HISTORY by statement shape and warehouse: each shape's spill per run times its runs on the table.
--   exec_rank, scan_rank, full_scan_rank and spill_rank order the tables by each measure (1 = heaviest,
--   NULL = none of it).
-- healthy: status is always OK: this ranks tables, it does not flag them.
-- investigate_if: never flags. Start from a table high on full scans or spill and read its top shapes in
--   sf_use_top_query_shapes; the cost of full scans is in sf_query_full_scans.
-- actions: 1) for full scans, filter on the column the table is loaded by, or cluster on the filter columns
--   (free, then spend); 2) for spill, a larger warehouse or a narrower query (config); 3) for query time
--   with good pruning, look at the warehouse in Queries > Waiting (free).
-- next: sf_query_full_scans, sf_use_top_query_shapes
-- empty_if: role_cannot_see, no_activity, ingestion_lag
-- caveats: a query's time and spill are the whole query's, so a join counts in full on each table it reads;
--   never add them across tables. Only the 1,000 longest scans per query are recorded, and hybrid tables are
--   not. Spill is shared out by statement shape, so a shape whose runs differ is evened out. The pruning
--   view lags up to 4 hours. Query compute in credits is not here: Snowflake has no per-table figure.
WITH tq AS (
  SELECT table_id, query_parameterized_hash, TO_VARCHAR(warehouse_id) AS warehouse_id,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(table_name) AS table_name,
         SUM(num_queries) AS runs, SUM(aggregate_query_execution_time) AS exec_ms,
         SUM(partitions_scanned) AS ps, SUM(partitions_pruned) AS pp, SUM(rows_scanned) AS rows_scanned
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND interval_start_time < __AS_OF_DATE__
    AND table_id IS NOT NULL
  GROUP BY table_id, query_parameterized_hash, TO_VARCHAR(warehouse_id)
),
spill AS (
  -- spill per run of each statement shape on each warehouse
  SELECT query_parameterized_hash, TO_VARCHAR(warehouse_id) AS warehouse_id,
         SUM(COALESCE(bytes_spilled_to_local_storage, 0) + COALESCE(bytes_spilled_to_remote_storage, 0))
           / COUNT(*) AS spill_per_run
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_parameterized_hash IS NOT NULL AND warehouse_id IS NOT NULL
  GROUP BY query_parameterized_hash, TO_VARCHAR(warehouse_id)
),
per AS (
  SELECT t.table_id,
         MAX(t.database_name) AS database_name, MAX(t.schema_name) AS schema_name, MAX(t.table_name) AS table_name,
         SUM(t.runs) AS queries, SUM(t.exec_ms) / 1000 AS exec_s,
         SUM(t.ps) AS partitions_scanned, SUM(t.rows_scanned) AS rows_scanned,
         SUM(IFF(t.query_parameterized_hash IS NOT NULL
                   AND (t.ps + t.pp) / NULLIF(t.runs, 0) >= :min_partitions
                   AND 100 * t.ps / NULLIF(t.ps + t.pp, 0) >= :scan_pct, t.runs, 0)) AS full_scan_queries,
         SUM(t.runs * s.spill_per_run) / POWER(1024, 3) AS spilled_gb
  FROM tq t
  LEFT JOIN spill s ON s.query_parameterized_hash = t.query_parameterized_hash AND s.warehouse_id = t.warehouse_id
  GROUP BY t.table_id
),
ranked AS (
  SELECT p.*,
         IFF(exec_s > 0, ROW_NUMBER() OVER (ORDER BY exec_s DESC, table_id), NULL) AS exec_rank,
         IFF(partitions_scanned > 0, ROW_NUMBER() OVER (ORDER BY partitions_scanned DESC, table_id), NULL) AS scan_rank,
         IFF(full_scan_queries > 0, ROW_NUMBER() OVER (ORDER BY full_scan_queries DESC, table_id), NULL) AS full_scan_rank,
         IFF(spilled_gb > 0, ROW_NUMBER() OVER (ORDER BY spilled_gb DESC NULLS LAST, table_id), NULL) AS spill_rank
  FROM per p
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       database_name, schema_name,
       COALESCE(table_name, 'table (' || table_id || ')') AS table_name, table_id,
       COALESCE(database_name || '.' || schema_name || '.' || table_name, 'table (' || table_id || ')') AS table_fqn,
       queries, exec_s, exec_s / NULLIF(queries, 0) AS avg_exec_s,
       partitions_scanned, rows_scanned, full_scan_queries, spilled_gb,
       exec_rank, scan_rank, full_scan_rank, spill_rank,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       'OK' AS status
FROM ranked
WHERE exec_rank <= :top_n OR scan_rank <= :top_n OR full_scan_rank <= :top_n OR spill_rank <= :top_n
ORDER BY COALESCE(exec_rank, 1e9), table_id
