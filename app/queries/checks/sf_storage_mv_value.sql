-- query_id: sf_storage_mv_value
-- title: Materialized views refreshed more than they are read
-- domain: storage   tier: standard
-- money: est_refresh_usd_list
-- entity: materialized views = mv_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_reads (default 30) reads: least a row needs before it can flag; :warn_usd (default 10)
--   usd: at or above this the row reads WARN; :crit_usd (default 100) usd: at or above this the row
--   reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a materialized view that spent refresh credits in the window. read_queries
--   counts queries that named it directly (ACCESS_HISTORY direct objects); usd_per_read is refresh cost
--   per read. est_storage_usd_month is what its stored result costs to keep.
-- healthy: status = OK when refreshes cost under warn_usd, or the view is read min_reads times or more.
-- investigate_if: WARN when refreshes cost warn_usd or more and it is read fewer than min_reads times;
--   CRITICAL at crit_usd, or when it is not read at all and costs warn_usd.
-- actions: 1) find the owner and whether dashboards query the base table instead (free); 2) ALTER
--   MATERIALIZED VIEW ... SUSPEND, or drop it (config); 3) replace it with a scheduled table or dynamic
--   table refreshed as often as it is actually read (engineering).
-- next: none
-- caveats: the optimizer can rewrite queries on the base table to use the view; those reads are not
--   counted, so check query profiles before dropping. ACCESS_HISTORY needs Enterprise Edition
--   (NOT_ASSESSED otherwise). Refresh credits lag up to 3 hours.
WITH mv AS (
  SELECT table_id, MAX(database_name || '.' || schema_name || '.' || table_name) AS mv_fqn,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name,
         MAX(table_name) AS mv_name,
         SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used))) AS credits, COUNT(*) AS refreshes
  FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
  HAVING SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used))) > 0
),
seen AS (
  SELECT COUNT(*) AS access_rows
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND query_start_time < __AS_OF_DATE__
),
reads AS (
  SELECT f.value:objectId::NUMBER AS object_id, COUNT(DISTINCT ah.query_id) AS read_queries,
         MAX(ah.query_start_time) AS last_read_at
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.direct_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
    AND f.value:objectDomain::STRING ILIKE 'materialized%'
  GROUP BY 1
),
sz AS (
  SELECT id, COALESCE(active_bytes, 0) + COALESCE(time_travel_bytes, 0)
           + COALESCE(failsafe_bytes, 0) AS stored_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
  WHERE NOT COALESCE(deleted, FALSE)
),
t AS (
  SELECT mv.*, COALESCE(r.read_queries, 0) AS read_queries, r.last_read_at, sz.stored_bytes,
         mv.credits * __CREDIT_PRICE__ AS usd
  FROM mv
  LEFT JOIN reads r ON r.object_id = mv.table_id
  LEFT JOIN sz ON sz.id = mv.table_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       mv_fqn, table_id AS mv_id, database_name, schema_name, mv_name,
       refreshes, credits AS refresh_credits, read_queries, last_read_at, stored_bytes,
       usd AS est_refresh_usd_list, usd / NULLIF(read_queries, 0) AS usd_per_read,
       stored_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS est_storage_usd_month,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       refreshes || ' refreshes (' || ROUND(credits, 1) || ' credits) for ' || read_queries
         || ' direct reads' AS waste_reason,
       CASE WHEN s.access_rows = 0 THEN 'no_access_history'
            WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN s.access_rows = 0 OR __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd AND read_queries < :min_reads THEN 'CRITICAL'
         WHEN usd >= :warn_usd AND read_queries = 0 THEN 'CRITICAL'
         WHEN usd >= :warn_usd AND read_queries < :min_reads THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t CROSS JOIN seen s
ORDER BY credits DESC
