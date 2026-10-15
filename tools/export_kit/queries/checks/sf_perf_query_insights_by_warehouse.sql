-- query_id: sf_perf_query_insights_by_warehouse
-- title: Share of each warehouse's compute spent on queries Snowflake flags for tuning
-- domain: performance   tier: standard
-- money: est_within_usd_list
-- entity: warehouses = warehouse_id
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_queries (default 5) queries: least a warehouse needs before it can flag; :warn_share_pct
--   (default 10) share pct: at or above this the row reads WARN; :crit_share_pct (default 30) share
--   pct: at or above this the row reads CRITICAL
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Insight types are read as ids only; message and suggestion text
--   is never read.
-- read_this: one row = one warehouse with queries Snowflake marked as a tuning opportunity. flagged_queries counts
--   distinct queries (a query with two insights counts once); dominant_insight is the type most of them carry.
--   attributed_credits is the compute Snowflake assigned to those queries, and flagged_share_pct is that over the
--   warehouse's credits in the window. est_within_usd_list prices it: a slice of the warehouse's spend, never
--   an addition to it.
-- healthy: status = OK when flagged queries are few or use a small share of the warehouse.
-- investigate_if: WARN when a warehouse with >= min_queries flagged queries uses >= warn_share_pct of its credits on
--   them; CRITICAL at >= crit_share_pct, however few the queries. NOT_ASSESSED when none of the flagged queries has an attribution row
--   yet or the warehouse has no metering in the window.
-- actions: 1) open the warehouse's costliest flagged query in Snowsight Query Profile and read its insight (free);
--   2) fix the SQL pattern (missing filter, join explosion, spill) before changing warehouse size (config);
--   3) resize or split the warehouse only after the SQL is fixed (spend)
-- next: sf_perf_query_insights_opportunities
-- not_assessed_reasons: no_attribution: none of the flagged queries has an attribution row (idle-time-only, under
--   about 100 ms, on an adaptive warehouse, or newer than the 8 h lag); no_warehouse_metering: the warehouse has no
--   metering rows in the window, so a share cannot be worked out
-- caveats: attributed compute leaves out idle time, cloud services and queries under about 100 ms, is NULL on
--   adaptive warehouses and lags up to 8 h, so it is a lower bound. Warehouse credits are compute plus billed cloud
--   services (after the 10 percent adjustment), so the share is of the warehouse's whole bill. QUERY_INSIGHTS lags up to
--   90 minutes and lists the last 2 weeks or more of insights depending on the account, so the share is worked out
--   over the days from the first insight in the window (credits and attribution are cut to the same days). Query
--   acceleration credits are billed apart from warehouse compute and are not in the share.
WITH -- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
cov AS (
  SELECT MIN(start_time) AS ins_start
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
ins AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name, query_id,
         COUNT(DISTINCT insight_type_id) AS types, MAX(insight_type_id) AS any_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS
  WHERE is_opportunity AND start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), query_id
),
kinds AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, insight_type_id, COUNT(DISTINCT query_id) AS n
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS
  WHERE is_opportunity AND start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), insight_type_id
),
dom AS (
  SELECT warehouse_id, MAX_BY(insight_type_id, n) AS dominant_insight, COUNT(*) AS insight_types
  FROM kinds
  GROUP BY warehouse_id
),
attr AS (
  SELECT query_id, SUM(COALESCE(credits_attributed_compute, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= (SELECT DATE_TRUNC('day', ins_start) FROM cov) AND start_time < __AS_OF_DATE__
  GROUP BY query_id
),
q AS (
  SELECT i.warehouse_id, MAX(i.warehouse_name) AS warehouse_name, COUNT(*) AS flagged_queries,
         COUNT_IF(a.query_id IS NOT NULL) AS attributed_queries, SUM(COALESCE(a.credits, 0)) AS attributed_credits
  FROM ins i LEFT JOIN attr a ON a.query_id = i.query_id
  GROUP BY i.warehouse_id
),
wm AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id,
         SUM(credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1)) AS warehouse_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= (SELECT DATE_TRUNC('day', ins_start) FROM cov) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id)
),
s AS (
  SELECT q.*, d.dominant_insight, d.insight_types, COALESCE(wm.warehouse_credits, 0) AS warehouse_credits,
         100 * q.attributed_credits / NULLIF(wm.warehouse_credits, 0) AS flagged_share_pct
  FROM q
  LEFT JOIN dom d ON d.warehouse_id = q.warehouse_id
  LEFT JOIN wm ON wm.warehouse_id = q.warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_name, warehouse_id,
       flagged_queries, attributed_queries, insight_types, dominant_insight, attributed_credits, warehouse_credits,
       flagged_share_pct, attributed_credits * __CREDIT_PRICE__ AS est_within_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN attributed_queries = 0 THEN 'no_attribution'
            WHEN warehouse_credits = 0 THEN 'no_warehouse_metering' END AS not_assessed_reason,
       CASE
         WHEN attributed_queries = 0 OR warehouse_credits = 0 THEN 'NOT_ASSESSED'
         -- a few flagged queries that take most of the warehouse still flag
         WHEN flagged_queries < :min_queries AND flagged_share_pct < :crit_share_pct THEN 'OK'
         WHEN flagged_share_pct >= :crit_share_pct THEN 'CRITICAL'
         WHEN flagged_share_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY attributed_credits DESC, warehouse_name
