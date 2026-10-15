-- query_id: query_pruning_effectiveness
-- title: File-pruning effectiveness per query group
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_prune_ratio (default 0.5) pruning ratio (pruned_files / (pruned_files + read_files))
--   below which a day flags WARN; :crit_prune_ratio (default 0.2) ... below which it flags CRITICAL;
--   :min_read_bytes (default 1073741824) minimum read_bytes_sum a day must have before it is judged on
--   its own - below it the day reads OK (too_small_to_judge); :min_recurring_flagged_days (default 2) number of
--   flagged days the same (account, compute_type, warehouse, identity, statement_type) pattern must
--   show in the window before a CRITICAL day is trusted alone - a one-off flagged day is capped at WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a day + warehouse + identity + statement_type whose queries pruned or read files
--   during a scan. The columns that matter are pruned_files_sum and read_files_sum - together they give
--   pruning_ratio (pruned / (pruned + read)); a low ratio on a repeating group means partition or file
--   layout, or the query's own predicates, are not letting Snowflake skip files it should be skipping.
--   days_seen and days_flagged say, for that same (account, compute_type, warehouse, identity,
--   statement_type) pattern across the whole window, how many days were observed and how many flagged
--   WARN or CRITICAL - a CRITICAL day that is a one-off (days_flagged below
--   :min_recurring_flagged_days) reads WARN instead, since one bad day is not the recurring-pattern
--   signal this query exists to surface.
-- healthy: pruning_ratio at/above :warn_prune_ratio (field heuristic - tune :warn_prune_ratio for your
--   account), or the day's read_bytes_sum is below :min_read_bytes (too little to matter: OK, with
--   too_small_to_judge = TRUE).
-- investigate_if: pruning_ratio below :warn_prune_ratio (WARN) or below :crit_prune_ratio (CRITICAL) -
--   field heuristic; a CRITICAL day only stays CRITICAL when days_flagged reaches
--   :min_recurring_flagged_days for that pattern, otherwise it is capped to WARN. A stable low ratio on
--   the same table/warehouse combination over several days is the real signal, not one bad day.
-- actions: 1) check whether your WHERE/JOIN predicates match the table's clustering key or its load
--   order (free); 2) set a clustering key on the columns these queries filter by, or use search
--   optimization for point lookups (config); 3) if the table is still poorly organized, rewrite it
--   sorted on those columns (spend - a rewrite cost).
-- next: none
-- caveats: Snowflake version: micro-partitions stand in for files: pruned = partitions_total -
--   partitions_scanned, read = partitions_scanned. No separate partition or rows-read counters
--   (read_partitions_sum and read_rows_sum are NULL).
WITH daily AS (
  SELECT DATE(start_time) AS day, TO_VARCHAR(warehouse_id) AS warehouse_id,
         MAX(warehouse_name) AS warehouse_name,
         user_name AS executed_by, query_type AS statement_type,
         COUNT(*) AS query_count,
         SUM(GREATEST(partitions_total - partitions_scanned, 0)) AS pruned_files_sum,
         SUM(partitions_scanned) AS read_files_sum,
         SUM(bytes_scanned) AS read_bytes_sum
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND partitions_total > 0
  GROUP BY DATE(start_time), TO_VARCHAR(warehouse_id), user_name, query_type
),
scored AS (
  SELECT d.*,
         pruned_files_sum / NULLIF(pruned_files_sum + read_files_sum, 0) AS pruning_ratio,
         CASE
           WHEN pruned_files_sum + read_files_sum = 0 THEN 'NOT_ASSESSED'
           -- the check ran; a day this small is not worth tuning
           WHEN read_bytes_sum < :min_read_bytes THEN 'OK'
           WHEN pruned_files_sum / NULLIF(pruned_files_sum + read_files_sum, 0) < :crit_prune_ratio THEN 'CRITICAL'
           WHEN pruned_files_sum / NULLIF(pruned_files_sum + read_files_sum, 0) < :warn_prune_ratio THEN 'WARN'
           ELSE 'OK'
         END AS day_status
  FROM daily d
),
enriched AS (
  SELECT s.*,
         COUNT(*) OVER (PARTITION BY warehouse_id, executed_by, statement_type) AS days_seen,
         COUNT_IF(day_status IN ('WARN', 'CRITICAL')) OVER (PARTITION BY warehouse_id, executed_by, statement_type) AS days_flagged
  FROM scored s
)
SELECT :period_days AS window_days, day, __ACCOUNT_ID__ AS account_id,
       IFF(warehouse_id IS NULL, 'CLOUD_SERVICES', 'WAREHOUSE') AS compute_type, warehouse_id, warehouse_name,
       executed_by, statement_type, query_count, pruned_files_sum, read_files_sum,
       CAST(NULL AS BIGINT) AS read_partitions_sum, read_bytes_sum, CAST(NULL AS BIGINT) AS read_rows_sum,
       ROUND(pruning_ratio, 3) AS pruning_ratio, days_seen, days_flagged,
       read_bytes_sum < :min_read_bytes AS too_small_to_judge,
       CASE WHEN pruned_files_sum + read_files_sum = 0 THEN 'no_partitions_read' END AS not_assessed_reason,
       -- a one-off CRITICAL day is capped to WARN
       IFF(day_status = 'CRITICAL' AND days_flagged < :min_recurring_flagged_days, 'WARN', day_status) AS status
FROM enriched
ORDER BY pruning_ratio ASC NULLS LAST
