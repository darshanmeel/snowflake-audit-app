-- query_id: sf_perf_table_pruning_regression
-- title: Tables whose partition pruning got worse in the last week
-- domain: performance   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_PRUNING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :lookback_days (default 56) days of history the check looks at, counted back from the
--   export date, the same in every window (a week has nothing to compare with) and cut into 7-day blocks (block 0 is the latest); :min_partitions (default 100000) partitions
--   (scanned plus pruned) a block needs before its ratio counts; :min_baseline_blocks (default 3)
--   earlier blocks with enough partitions needed for a baseline; :warn_drop_pts (default 15) prune
--   ratio points lost against the baseline: at or above this the row reads WARN; :crit_drop_pts
--   (default 30) points lost: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table. prune_ratio is partitions skipped over all partitions in a 7-day
--   block, from summed counts (never an average of ratios). baseline_prune_ratio is the median of the
--   earlier blocks; last_prune_ratio is the latest complete block. drop_pts is the difference, and
--   extra_partitions_scanned is what the last block read above what the baseline ratio would have read.
-- healthy: status = OK when the last block prunes about as well as before, or the table is scanned too
--   little to judge (only tables with enough scans in the last block or the baseline are listed).
-- investigate_if: WARN when the ratio dropped by warn_drop_pts or more, CRITICAL at crit_drop_pts.
--   NOT_ASSESSED when there is no baseline or the last block had too little scanning.
-- actions: 1) check whether the table was rebuilt, reloaded out of order or its clustering key changed
--   in the last block (see ddl_in_last_block) (free); 2) look at the filters of the new queries that
--   scan it (free); 3) recluster the table or fix the load order (spend).
-- next: none
-- empty_if: view_missing, role_cannot_see, no_activity, ingestion_lag
-- not_assessed_reasons: no_baseline: fewer than min_baseline_blocks earlier blocks had enough
--   partitions; too_little_scanning: the last block scanned fewer than min_partitions partitions
-- caveats: blocks end at the export date, so today is left out. Zero-scan blocks stay in the block
--   count but not in the baseline. The view lags up to 6 h and skips hybrid tables. The clustering
--   state is stored as yes or no only.
WITH hourly AS (
  SELECT table_id, database_name, schema_name, table_name,
         FLOOR((DATEDIFF(day, DATE(start_time), __AS_OF_DATE__) - 1) / 7) AS blk,
         num_scans, partitions_scanned, partitions_pruned
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_PRUNING_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
blocks AS (
  SELECT seq4() AS blk FROM TABLE(GENERATOR(ROWCOUNT => 60))
),
tbl AS (
  SELECT table_id,
         MAX(database_name || '.' || schema_name || '.' || table_name) AS table_name
  FROM hourly
  GROUP BY table_id
),
spine AS (
  SELECT t.table_id, b.blk
  FROM tbl t CROSS JOIN blocks b
  WHERE b.blk < FLOOR(:lookback_days / 7)
),
wk AS (
  SELECT sp.table_id, sp.blk,
         COALESCE(SUM(h.num_scans), 0) AS scans,
         COALESCE(SUM(h.partitions_scanned), 0) AS ps,
         COALESCE(SUM(h.partitions_pruned), 0) AS pp
  FROM spine sp
  LEFT JOIN hourly h ON h.table_id = sp.table_id AND h.blk = sp.blk
  GROUP BY sp.table_id, sp.blk
),
base AS (
  SELECT table_id,
         COUNT_IF(pp + ps >= :min_partitions) AS baseline_blocks,
         MEDIAN(IFF(pp + ps >= :min_partitions, pp / NULLIF(pp + ps, 0), NULL)) AS baseline_ratio
  FROM wk
  WHERE blk >= 1
  GROUP BY table_id
),
last_ AS (
  SELECT table_id, scans AS last_scans, ps AS last_ps, pp AS last_pp
  FROM wk
  WHERE blk = 0
),
tb AS (
  SELECT table_id,
         MAX(IFF(clustering_key IS NULL, 'no', 'yes')) AS is_clustered,
         MAX(IFF(DATEDIFF(day, last_ddl, __AS_OF_DATE__) <= 7, 'yes', 'no')) AS ddl_in_last_block
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  GROUP BY table_id
),
s AS (
  SELECT t.table_id, t.table_name, b.baseline_blocks, b.baseline_ratio,
         l.last_scans, l.last_ps + l.last_pp AS last_partitions,
         l.last_pp / NULLIF(l.last_ps + l.last_pp, 0) AS last_ratio,
         tb.is_clustered, tb.ddl_in_last_block
  FROM tbl t
  LEFT JOIN base b ON b.table_id = t.table_id
  LEFT JOIN last_ l ON l.table_id = t.table_id
  LEFT JOIN tb ON tb.table_id = t.table_id
),
d AS (
  SELECT s.*, 100 * (baseline_ratio - last_ratio) AS drop_pts
  FROM s
  WHERE COALESCE(last_partitions, 0) >= :min_partitions OR COALESCE(baseline_blocks, 0) >= 1
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       COALESCE(table_name, 'unknown') || ' (' || TO_VARCHAR(table_id) || ')' AS table_name,
       is_clustered, ddl_in_last_block, baseline_blocks,
       ROUND(100 * baseline_ratio, 1) AS baseline_prune_ratio,
       ROUND(100 * last_ratio, 1) AS last_prune_ratio,
       ROUND(drop_pts, 1) AS drop_pts, last_scans, last_partitions,
       GREATEST(last_partitions * (baseline_ratio - last_ratio), 0) AS extra_partitions_scanned,
       CASE WHEN COALESCE(baseline_blocks, 0) < :min_baseline_blocks THEN 'no_baseline'
            WHEN COALESCE(last_partitions, 0) < :min_partitions THEN 'too_little_scanning' END AS not_assessed_reason,
       CASE
         WHEN COALESCE(baseline_blocks, 0) < :min_baseline_blocks THEN 'NOT_ASSESSED'
         WHEN COALESCE(last_partitions, 0) < :min_partitions THEN 'NOT_ASSESSED'
         WHEN drop_pts >= :crit_drop_pts THEN 'CRITICAL'
         WHEN drop_pts >= :warn_drop_pts THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM d
ORDER BY drop_pts DESC NULLS LAST, last_partitions DESC NULLS LAST
