-- query_id: sf_dt_unread_refresh_cost
-- title: Dynamic tables refreshed for nobody
-- domain: jobs_pipelines   tier: standard
-- entity: dynamic tables = dt_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 10) usd: at or above this an unread table reads WARN; :crit_usd (default
--   100) usd: at or above this an unread table reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live dynamic table refreshed in the window. consumer_read_queries counts
--   distinct queries that read it; dt_refresh_read_queries counts reads by other dynamic tables'
--   refreshes (it feeds a chain, so judge the end of the chain). est_refresh_usd_list is at least what
--   its refreshes cost, from per-query attribution. The possible-waste column is that cost when nothing
--   read the table; it is part of the refresh cost, not on top of it.
-- healthy: status = OK when something reads the table (a query or another dynamic table), or its
--   refreshes cost under warn_usd.
-- investigate_if: WARN when nothing read the table and its refreshes cost warn_usd or more; CRITICAL at
--   crit_usd.
-- actions: 1) confirm nobody needs it (a dashboard outside the window, a share, a monthly report) (free);
--   2) raise TARGET_LAG or ALTER DYNAMIC TABLE ... SUSPEND while it is not needed (config); 3) drop the
--   table and anything that only feeds it (config).
-- next: sf_dt_cost
-- empty_if: edition_too_low, view_missing, no_activity, ingestion_lag
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the refresh cost
--   cannot be priced; no_access_history: ACCESS_HISTORY (Enterprise edition) has no rows, so reads are
--   not known; no_attributed_usage: none of the refreshes has an attributed cost row yet, so the cost is
--   not known
-- caveats: reads need ACCESS_HISTORY (Enterprise edition, lags up to 3 hours). Refresh cost comes from
--   query attribution, which leaves out warehouse idle time and queries under about 100 ms, is empty on
--   adaptive warehouses and lags up to 8 hours, so it is a floor and never $0 when unknown.
WITH -- Current table id of each live table by full name, for dynamic tables whose refresh history
-- carries names only. Dropped tables have no id here, so their rows keep the name alone.
sf_dt_dim AS (
  SELECT table_catalog || '.' || table_schema || '.' || table_name AS dt_full_name,
         MAX(TO_VARCHAR(table_id)) AS dt_id, MAX(table_owner) AS owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  GROUP BY 1
),
r AS (
  SELECT database_name || '.' || schema_name || '.' || name AS dt_full_name,
         name AS dt_name, database_name, schema_name, id, query_id, refresh_action
  FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
  WHERE data_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND data_timestamp < __AS_OF_DATE__
    AND query_id IS NOT NULL
),
attr AS (
  SELECT COALESCE(root_query_id, query_id) AS refresh_query_id, MAX(warehouse_name) AS warehouse_name,
         SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__) AND start_time < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY 1
),
dt AS (
  SELECT r.dt_full_name, MAX(r.dt_name) AS dt_name, MAX(r.database_name) AS database_name,
         MAX(r.schema_name) AS schema_name, MAX(TO_VARCHAR(r.id)) AS history_id,
         MAX(a.warehouse_name) AS warehouse_name,
         COUNT(*) AS refreshes,
         COUNT_IF(r.refresh_action IN ('FULL', 'INCREMENTAL', 'REINITIALIZE', 'CUSTOM_INCREMENTAL')) AS data_refreshes,
         COUNT_IF(a.refresh_query_id IS NOT NULL) AS attributed_refreshes,
         SUM(a.credits) AS credits
  FROM r LEFT JOIN attr a ON a.refresh_query_id = r.query_id
  GROUP BY r.dt_full_name
),
dtl AS (
  SELECT dt.*, d.dt_id, d.owner, d.dt_id IS NULL AS is_dropped,
         COALESCE(d.dt_id, dt.history_id) AS read_id
  FROM dt LEFT JOIN sf_dt_dim d ON d.dt_full_name = dt.dt_full_name
),
-- One row per query and object, so a query that touches a table several times is one read.
reads AS (
  SELECT DISTINCT ah.query_id, TO_VARCHAR(f.value:"objectId"::NUMBER) AS object_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT())), OUTER => TRUE) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
rd AS (
  SELECT x.object_id,
         COUNT(DISTINCT IFF(rq.query_id IS NULL, x.query_id, NULL)) AS consumer_read_queries,
         -- A table's own refresh MERGE lists it as accessed, so that refresh is not a read of it.
         COUNT(DISTINCT IFF(rq.query_id IS NOT NULL AND TO_VARCHAR(rq.id) <> x.object_id, x.query_id, NULL))
           AS dt_refresh_read_queries
  FROM reads x LEFT JOIN r rq ON rq.query_id = x.query_id
  WHERE x.object_id IN (SELECT read_id FROM dtl)
  GROUP BY x.object_id
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM (
    SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
    WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
    LIMIT 1)
),
s AS (
  SELECT dtl.*, COALESCE(rd.consumer_read_queries, 0) AS consumer_read_queries,
         COALESCE(rd.dt_refresh_read_queries, 0) AS dt_refresh_read_queries,
         COALESCE(dtl.credits, 0) * __CREDIT_PRICE__ AS usd,
         COALESCE(rd.consumer_read_queries, 0) + COALESCE(rd.dt_refresh_read_queries, 0) = 0 AS is_unread
  FROM dtl LEFT JOIN rd ON rd.object_id = dtl.read_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       dt_full_name, dt_name, dt_id, database_name, schema_name, owner, warehouse_name, is_dropped,
       refreshes, data_refreshes, attributed_refreshes,
       consumer_read_queries, dt_refresh_read_queries,
       COALESCE(credits, 0) AS credits,
       usd AS est_refresh_usd_list,
       IFF(is_unread AND NOT is_dropped, usd, NULL) AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(COALESCE(credits, 0), 2) || ' credits over ' || refreshes || ' refreshes, '
         || (consumer_read_queries + dt_refresh_read_queries) || ' reads' AS waste_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN a.access_rows = 0 THEN 'no_access_history'
            WHEN attributed_refreshes = 0 THEN 'no_attributed_usage' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR a.access_rows = 0 OR attributed_refreshes = 0 THEN 'NOT_ASSESSED'
         WHEN is_dropped OR NOT is_unread THEN 'OK'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s CROSS JOIN seen a
ORDER BY est_wasted_usd_list DESC NULLS LAST, credits DESC NULLS LAST
