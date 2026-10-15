-- query_id: sf_obj_catalog_linked_db_cost
-- title: Catalog-linked databases: what syncing costs against reads
-- domain: cost   tier: standard
-- entity: catalog-linked databases = database_name
-- windowed: yes
-- money: est_wasted_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CATALOG_LINKED_DATABASE_USAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition for the reads (ACCESS_HISTORY)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 20) usd: an unread database at or above this reads WARN; :crit_usd (default 200)
--   usd: an unread database at or above this reads CRITICAL; :warn_increase_pct (default 50) increase pct:
--   growth over the previous window at or above this flags
-- empty_if: no_activity, view_missing, edition_too_low
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That a read of a table in the database lists the database name
--   as the first part of objectName is taken from the docs. Quotes are stripped and the match ignores case, so
--   two databases differing only in case read as one; a name with a dot inside quotes would not match. The
--   ACCESS_HISTORY scan over the window is heavy on a large account.
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the sync cost cannot be
--   priced; no_access_history: ACCESS_HISTORY (Enterprise edition) has no rows, so reads are not known
-- read_this: one row = one catalog-linked database. compute_credits (table creation) are priced; cloud_services_credits
--   (table discovery and deletion) are shown in credits and not priced, because they are billed only above the
--   10% daily cloud services allowance. read_queries are queries that read an object in the database. est_wasted_usd_list
--   is the compute cost of a database nobody read: a slice of est_usd_list, never added to it.
-- healthy: status = OK when the database is read, or costs little.
-- investigate_if: WARN when an unread database costs at least warn_usd, or its compute credits grew
--   warn_increase_pct or more; CRITICAL when an unread database costs at least crit_usd.
-- actions: 1) drop or unlink a catalog-linked database nobody reads (config); 2) narrow the sync to the
--   namespaces that are used (config); 3) ask the catalog owner to stop creating tables you do not query
--   (engineering).
-- next: sf_obj_iceberg_tables
-- caveats: An account with no catalog-linked database returns no rows: it does not use the feature. Without
--   ACCESS_HISTORY reads read empty and no waste is shown. Cloud services credits are gross; the bill takes
--   them only past the daily 10% adjustment. The history lags with the account usage views, up to 3 hours.
WITH c AS (
  SELECT TO_VARCHAR(database_id) AS database_id, MAX_BY(database_name, start_time) AS database_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), COALESCE(credits_used_compute, 0), 0)) AS compute_credits,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), COALESCE(credits_used_cloud_services, 0), 0)) AS cloud_services_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), COALESCE(credits_used_compute, 0), 0)) AS prev_compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CATALOG_LINKED_DATABASE_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
rd AS (
  SELECT UPPER(TRIM(SPLIT_PART(f.value:"objectName"::VARCHAR, '.', 1), '"')) AS db_key, COUNT(DISTINCT ah.query_id) AS read_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT())), OUTER => TRUE) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND ah.query_start_time < __AS_OF_DATE__
  GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM (
    SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
    WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
    LIMIT 1)
),
s AS (
  SELECT c.*, seen.access_rows, IFF(seen.access_rows = 0, NULL, COALESCE(rd.read_queries, 0)) AS read_queries,
         c.compute_credits * __CREDIT_PRICE__ AS usd,
         100 * (c.compute_credits - c.prev_compute_credits) / NULLIF(c.prev_compute_credits, 0) AS increase_pct
  FROM c
  LEFT JOIN rd ON rd.db_key = UPPER(c.database_name)
  CROSS JOIN seen
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, database_name, database_id, compute_credits,
       cloud_services_credits, prev_compute_credits, increase_pct, read_queries,
       usd AS est_usd_list,
       IFF(read_queries = 0, usd, NULL) AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(read_queries = 0, 'no query read it in ' || :period_days || ' days', NULL),
         IFF(increase_pct >= :warn_increase_pct, 'compute credits up ' || ROUND(increase_pct) || '% on the previous window', NULL)), '; ') AS reasons,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN access_rows = 0 THEN 'no_access_history' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR access_rows = 0 THEN 'NOT_ASSESSED'
         WHEN read_queries = 0 AND usd >= :crit_usd THEN 'CRITICAL'
         WHEN (read_queries = 0 AND usd >= :warn_usd) OR (usd >= :warn_usd AND increase_pct >= :warn_increase_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END, usd DESC NULLS LAST
