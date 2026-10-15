-- query_id: sf_obj_iceberg_compaction_cost
-- title: Iceberg table compaction cost against reads
-- domain: storage   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ICEBERG_STORAGE_OPTIMIZATION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 25) usd: at or above this the row can read WARN; :crit_usd (default 250)
--   usd: at or above this an unread table reads CRITICAL; :warn_usd_per_read (default 0.5) usd per read:
--   compaction cost per reading query at or above this reads WARN; :warn_usd_per_tb (default 50) usd per
--   tb: compaction cost per TB of table size at or above this reads WARN; :warn_growth_pct (default 50)
--   growth pct: at or above this the row reads WARN; :min_growth_usd (default 10) growth usd: least a
--   row needs before growth can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one Iceberg table (Snowflake-managed or Open Catalog) that spent compaction
--   credits in the window. read_queries counts queries that read it, or is empty when ACCESS_HISTORY is
--   not available (Standard edition). est_usd_per_tb is the compaction cost per TB of table size, and
--   prev_credits the same-length window before. The possible-waste column is the compaction cost of a
--   table nobody read; it is part of the spend column, not on top of it.
-- healthy: status = OK when compaction costs under warn_usd, or the table is read and the cost is low
--   per read, per TB and not growing fast.
-- investigate_if: WARN when cost is warn_usd or more and the table is unread, costs warn_usd_per_read or
--   more per read, warn_usd_per_tb or more per TB, or grew warn_growth_pct (and min_growth_usd); CRITICAL
--   when cost is crit_usd or more and the table is unread.
-- actions: 1) check if the table is still used, or write to it in fewer, bigger batches so there is less
--   to compact (free); 2) drop or stop writing to tables nobody reads (config); 3) review the table's
--   partitioning and file sizes with the Iceberg engine that writes it (config).
-- next: sf_obj_iceberg_tables
-- empty_if: view_missing, no_activity, ingestion_lag
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the compaction cost
--   cannot be priced
-- caveats: compaction credits are on all editions (lag 2 hours); the read signal needs Enterprise edition
--   (ACCESS_HISTORY, lag up to 3 hours) and reads show a dash without it. Only tables Snowflake
--   compacts are listed, not externally managed ones. Compaction is serverless spend priced at the
--   account credit price.
WITH ic AS (
  SELECT table_id, MAX(database_name || '.' || schema_name || '.' || table_name) AS table_fqn_hist,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS prev_credits,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), num_bytes_scanned, 0)) AS bytes_scanned,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), num_rows_written, 0)) AS rows_written
  FROM SNOWFLAKE.ACCOUNT_USAGE.ICEBERG_STORAGE_OPTIMIZATION_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
),
-- One row per query and table, so a query that touches a table twice is one read.
reads AS (
  SELECT DISTINCT ah.query_id, f.value:"objectId"::NUMBER AS table_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT())), OUTER => TRUE) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
rd AS (
  SELECT table_id, COUNT(*) AS read_queries
  FROM reads
  WHERE table_id IN (SELECT table_id FROM ic)
  GROUP BY table_id
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM (
    SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
    WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
    LIMIT 1)
),
t AS (
  SELECT ic.table_id,
         COALESCE(tb.table_catalog || '.' || tb.table_schema || '.' || tb.table_name, ic.table_fqn_hist) AS table_fqn,
         tb.table_id IS NULL AS is_dropped, tb.bytes AS table_bytes,
         ic.credits, ic.prev_credits, ic.bytes_scanned, ic.rows_written,
         IFF(a.access_rows = 0, NULL, COALESCE(rd.read_queries, 0)) AS read_queries,
         ic.credits * __CREDIT_PRICE__ AS usd,
         ic.prev_credits * __CREDIT_PRICE__ AS prev_usd
  FROM ic
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES tb ON tb.table_id = ic.table_id AND tb.deleted IS NULL
  LEFT JOIN rd ON rd.table_id = ic.table_id
  CROSS JOIN seen a
  WHERE ic.credits > 0 OR ic.prev_credits > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, TO_VARCHAR(table_id) AS table_id, is_dropped,
       ROUND(table_bytes / POWER(1024, 3), 2) AS table_gb, credits AS compaction_credits, prev_credits,
       ROUND(bytes_scanned / POWER(1024, 3), 2) AS gb_scanned, rows_written, read_queries,
       100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
       usd AS est_compaction_usd_list, prev_usd AS est_prev_usd_list,
       usd - prev_usd AS est_delta_usd_list,
       usd / NULLIF(read_queries, 0) AS est_usd_per_read_query,
       usd / NULLIF(table_bytes / POWER(1024, 4), 0) AS est_usd_per_tb,
       IFF(read_queries = 0, usd, NULL) AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(credits, 2) || ' compaction credits, ' || COALESCE(TO_VARCHAR(read_queries), 'unknown')
         || ' reading queries' AS waste_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd AND read_queries = 0 THEN 'CRITICAL'
         WHEN usd >= :warn_usd
           AND (read_queries = 0
                OR usd / NULLIF(read_queries, 0) >= :warn_usd_per_read
                OR usd / NULLIF(table_bytes / POWER(1024, 4), 0) >= :warn_usd_per_tb
                OR (usd - prev_usd >= :min_growth_usd
                    AND 100 * (credits - prev_credits) / NULLIF(prev_credits, 0) >= :warn_growth_pct)) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY credits DESC
