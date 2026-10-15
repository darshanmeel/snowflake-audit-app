-- query_id: sf_perf_table_scan_selectivity
-- title: Table scans that read far more rows than they keep
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_rows_scanned (default 100000000) rows scanned: least a row needs before it is judged;
--   :min_queries (default 10) queries: least a row needs before it is judged; :warn_matched_pct
--   (default 1) matched pct: below this the row reads WARN; :crit_matched_pct (default 0.1) matched pct:
--   below this and at or above crit_usd the row reads CRITICAL; :crit_usd (default 50) attributed usd
--   needed for CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table + one warehouse + one statement shape (parameterized hash).
--   matched_pct is rows that passed the WHERE filter over rows scanned; a very low value on many
--   queries means the scan reads the table and throws almost everything away. prune_pct is partitions
--   skipped over all partitions. attributed_credits is the shape's compute split across its tables by
--   execution time share (shares add to 1), so it is a slice, not a saving.
-- healthy: status = OK when scans keep a fair part of what they read, or the volume is small.
-- investigate_if: WARN when matched_pct is below warn_matched_pct on at least min_rows_scanned rows and
--   min_queries queries; CRITICAL when it is below crit_matched_pct and the attributed compute is at or
--   above crit_usd. NOT_ASSESSED when no rows were measured.
-- actions: 1) check the filter columns against the table's clustering key and whether the filter wraps
--   the column in a function (free); 2) add or change the clustering key, or filter earlier in the
--   query (config); 3) recluster or rebuild the table around the filter column (spend).
-- next: none
-- empty_if: view_missing, role_cannot_see, no_activity, ingestion_lag
-- not_assessed_reasons: no_rows_measured: the scans in this row report no rows scanned
-- caveats: the view keeps the 1,000 longest scans per query and skips hybrid tables, so counts are a
--   floor. Attributed compute is at least this much: it leaves out idle time and queries under about
--   100 ms, is NULL on adaptive warehouses, lags up to 8 h and is never added to spend. The clustering
--   key is stored as yes or no only.
WITH t AS (
  SELECT table_id, TO_VARCHAR(warehouse_id) AS warehouse_id, query_parameterized_hash,
         MAX(warehouse_name) AS warehouse_name,
         MAX(database_name || '.' || schema_name || '.' || table_name) AS table_name,
         SUM(num_queries) AS queries,
         SUM(aggregate_query_execution_time) AS exec_ms,
         SUM(partitions_scanned) AS partitions_scanned,
         SUM(partitions_pruned) AS partitions_pruned,
         SUM(rows_scanned) AS rows_scanned,
         SUM(rows_matched) AS rows_matched
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__
  GROUP BY table_id, TO_VARCHAR(warehouse_id), query_parameterized_hash
),
shape AS (
  SELECT warehouse_id, query_parameterized_hash, SUM(exec_ms) AS shape_exec_ms
  FROM t
  GROUP BY warehouse_id, query_parameterized_hash
),
qa AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, query_parameterized_hash,
         SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), query_parameterized_hash
),
tb AS (
  SELECT table_id, MAX(IFF(clustering_key IS NULL, 'no', 'yes')) AS is_clustered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  GROUP BY table_id
),
s AS (
  SELECT t.*, tb.is_clustered,
         100 * t.rows_matched / NULLIF(t.rows_scanned, 0) AS matched_pct,
         100 * t.partitions_pruned / NULLIF(t.partitions_pruned + t.partitions_scanned, 0) AS prune_pct,
         qa.credits * t.exec_ms / NULLIF(shape.shape_exec_ms, 0) AS attributed_credits
  FROM t
  LEFT JOIN shape ON shape.warehouse_id = t.warehouse_id
    AND shape.query_parameterized_hash = t.query_parameterized_hash
  LEFT JOIN qa ON qa.warehouse_id = t.warehouse_id
    AND qa.query_parameterized_hash = t.query_parameterized_hash
  LEFT JOIN tb ON tb.table_id = t.table_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       COALESCE(table_name, 'unknown') || ' (' || TO_VARCHAR(table_id) || ')' AS table_name,
       COALESCE(warehouse_name, 'unknown') || ' (' || COALESCE(warehouse_id, 'unknown') || ')' AS warehouse,
       query_parameterized_hash, is_clustered, queries, exec_ms / 3600000.0 AS exec_hours,
       rows_scanned, rows_matched, ROUND(matched_pct, 4) AS matched_pct,
       partitions_scanned, partitions_pruned, ROUND(prune_pct, 1) AS prune_pct,
       attributed_credits,
       attributed_credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       'attributed compute, at least: excludes idle time and queries under about 100 ms' AS attribution_note,
       CASE WHEN COALESCE(rows_scanned, 0) = 0 THEN 'no_rows_measured' END AS not_assessed_reason,
       CASE
         WHEN COALESCE(rows_scanned, 0) = 0 THEN 'NOT_ASSESSED'
         WHEN rows_scanned < :min_rows_scanned OR queries < :min_queries THEN 'OK'
         WHEN matched_pct < :crit_matched_pct AND attributed_credits * __CREDIT_PRICE__ >= :crit_usd THEN 'CRITICAL'
         WHEN matched_pct < :warn_matched_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY rows_scanned DESC NULLS LAST
