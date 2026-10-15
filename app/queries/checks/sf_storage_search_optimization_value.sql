-- query_id: sf_storage_search_optimization_value
-- title: Search optimization that may not pay
-- domain: storage   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_BENEFITS, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_reads (default 100) reads: least a row needs before it can flag; :poor_scan_pct (default
--   50) poor scan pct: value this check uses; :warn_usd (default 25) usd: at or above this the row
--   reads WARN; :crit_usd (default 250) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a table that spent search optimization (build/maintenance) credits in the
--   window. read_queries counts queries that read it; avg_scan_pct is the partitions scanned by
--   single-table queries (search optimization should keep point lookups well under 10%). usd_per_read
--   is the upkeep per read. scans_helped and extra_pruned_pct are Snowflake's own count of scans that
--   used the search access path and the share of partitions it pruned beyond natural order.
-- healthy: status = OK when upkeep is under warn_usd, or the table is read min_reads times with
--   avg_scan_pct under poor_scan_pct and, when the benefits view has rows for the account, some of its
--   scans used search optimization.
-- investigate_if: WARN when upkeep is warn_usd or more and the table is rarely read, still scans
--   poor_scan_pct of partitions, or has no benefit rows while other tables do; CRITICAL at crit_usd with
--   those signs.
-- actions: 1) run SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS and check which columns the lookups
--   filter on (free); 2) ALTER TABLE ... DROP SEARCH OPTIMIZATION, or limit it with ON EQUALITY(col) to
--   the columns actually searched (config); 3) batch DML on the table so maintenance runs less.
-- next: none
-- caveats: Snowflake records search optimization use per scan only in SEARCH_OPTIMIZATION_BENEFITS, so
--   value is also inferred from reads and pruning; an empty benefits view is not read as no use. Search optimization storage is not included. ACCESS_HISTORY needs
--   Enterprise Edition (NOT_ASSESSED otherwise). Benefit rows lag up to 6 hours and keep only the 1,000
--   longest scans per query, so scans_helped is a floor.
WITH __INCLUDE_sf_storage_live_tables__,
__INCLUDE_sf_storage_table_use__,
so AS (
  -- BASE_TABLE_ID/NAME or TABLE_ID/NAME, whichever the view has while the rename rolls out.
  SELECT COALESCE(o:BASE_TABLE_ID, o:TABLE_ID)::NUMBER AS table_id,
         MAX(database_name || '.' || schema_name || '.' || COALESCE(o:BASE_TABLE_NAME, o:TABLE_NAME)::VARCHAR)
           AS table_fqn_hist,
         SUM(credits_used) AS credits, COUNT(*) AS maintenance_runs
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o, start_time, credits_used, database_name, schema_name
        FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY COALESCE(o:BASE_TABLE_ID, o:TABLE_ID)::NUMBER
  HAVING SUM(credits_used) > 0
),
-- Benefits are summed per table before the join, so a table's credits are never repeated per hour.
b AS (
  SELECT table_id, SUM(num_scans) AS scans_helped,
         100 * SUM(partitions_pruned_additional)
           / NULLIF(SUM(partitions_scanned) + SUM(partitions_pruned_additional), 0) AS extra_pruned_pct
  FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_BENEFITS
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
),
t AS (
  SELECT so.*, COALESCE(lt.table_fqn, so.table_fqn_hist) AS table_fqn,
         COALESCE(b.scans_helped, 0) AS scans_helped, b.extra_pruned_pct, lt.active_bytes, lt.row_count,
         lt.table_id IS NULL AS is_dropped,
         COALESCE(u.read_queries, 0) AS read_queries, u.last_read_at, u.single_table_queries,
         u.avg_scan_pct, so.credits * __CREDIT_PRICE__ AS usd,
         -- no benefit rows for this table while the view has rows for others: its scans never used it
         (COALESCE(u.read_queries, 0) < :min_reads OR COALESCE(u.avg_scan_pct, 0) >= :poor_scan_pct
          OR (b.table_id IS NULL AND (SELECT COUNT(*) FROM b) > 0)) AS doubtful_value
  FROM so
  LEFT JOIN sf_storage_live_tables lt ON lt.table_id = so.table_id
  LEFT JOIN sf_storage_table_use u ON u.table_id = so.table_id
  LEFT JOIN b ON b.table_id = so.table_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, t.table_id, is_dropped, active_bytes, row_count, maintenance_runs,
       credits AS search_optimization_credits, read_queries, last_read_at, single_table_queries,
       ROUND(avg_scan_pct, 1) AS avg_scan_pct, scans_helped, ROUND(extra_pruned_pct, 1) AS extra_pruned_pct,
       usd AS est_search_optimization_usd_list, usd / NULLIF(read_queries, 0) AS usd_per_read,
       usd / NULLIF(scans_helped, 0) * 1000 AS est_usd_per_1k_scans_helped,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(credits, 1) || ' search optimization credits for ' || read_queries || ' reads' AS waste_reason,
       CASE WHEN a.access_rows = 0 THEN 'no_access_history'
            WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN a.access_rows = 0 OR __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd AND doubtful_value THEN 'CRITICAL'
         WHEN usd >= :warn_usd AND doubtful_value THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t CROSS JOIN sf_storage_access_seen a
ORDER BY credits DESC
