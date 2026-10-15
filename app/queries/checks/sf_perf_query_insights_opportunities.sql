-- query_id: sf_perf_query_insights_opportunities
-- title: Queries Snowflake flags as anti-patterns, with the compute they used
-- domain: performance   tier: standard
-- entity: query shapes = warehouse, query_parameterized_hash
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 25) attributed usd: at or above this the row reads WARN; :crit_usd
--   (default 250) attributed usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse + insight type + statement shape (parameterized hash) that Snowflake marked
--   as an improvement opportunity. queries counts distinct queries; attributed_credits is the per-query
--   compute Snowflake assigned to them. A query with several insight types shows in several rows, so
--   rows are not additive.
-- healthy: status = OK when the flagged shapes used little compute.
-- investigate_if: WARN when a shape's attributed compute is >= warn_usd, CRITICAL at >= crit_usd.
--   NOT_ASSESSED when none of its queries has an attribution row yet (see not_assessed_reason).
-- actions: 1) open the slowest query of the shape in Snowsight Query Profile and read the insight
--   (free); 2) add the missing join condition or filter, or pre-aggregate before the join (config);
--   3) move a heavy shape to its own warehouse only after the SQL is fixed (spend).
-- next: none
-- empty_if: view_missing, role_cannot_see, no_activity
-- not_assessed_reasons: unpriced: no credit price is available for the window, so compute cannot be
--   priced; no_attribution: none of the flagged queries has an attribution row (idle-time-only, under
--   about 100 ms, on an adaptive warehouse, or newer than the 8 h lag)
-- caveats: attributed compute leaves out idle time, cloud services and queries under about 100 ms, is
--   NULL on adaptive warehouses and lags up to 8 h, so it is a lower bound and never added to warehouse
--   spend. QUERY_INSIGHTS lags up to 90 min. Insight text and suggestions are never read.
WITH qi AS (
  SELECT query_id, insight_type_id,
         MAX(insight_topic) AS insight_topic,
         MAX(query_parameterized_hash) AS query_parameterized_hash,
         MAX(warehouse_id) AS warehouse_id,
         MAX(warehouse_name) AS warehouse_name,
         MAX(total_elapsed_time) AS elapsed_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_INSIGHTS
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND is_opportunity = TRUE
  GROUP BY query_id, insight_type_id
),
qa AS (
  SELECT query_id, SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY query_id
),
j AS (
  SELECT qi.*, qa.credits
  FROM qi LEFT JOIN qa ON qa.query_id = qi.query_id
),
g AS (
  SELECT COALESCE(TO_VARCHAR(warehouse_id), 'unknown') AS warehouse_id,
         COALESCE(MAX(warehouse_name), 'unknown') AS warehouse_name,
         insight_type_id, MAX(insight_topic) AS insight_topic,
         COALESCE(query_parameterized_hash, 'unknown') AS query_parameterized_hash,
         COUNT(*) AS queries,
         COUNT_IF(credits IS NOT NULL) AS attributed_queries,
         SUM(elapsed_ms) / 3600000.0 AS elapsed_hours,
         SUM(credits) AS attributed_credits
  FROM j
  GROUP BY COALESCE(TO_VARCHAR(warehouse_id), 'unknown'), insight_type_id, COALESCE(query_parameterized_hash, 'unknown')
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       warehouse_name || ' (' || warehouse_id || ')' AS warehouse,
       insight_type_id, insight_topic, query_parameterized_hash,
       queries, attributed_queries, elapsed_hours, attributed_credits,
       attributed_credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       'attributed compute, lower bound: excludes idle time and queries under about 100 ms' AS attribution_note,
       CASE WHEN attributed_queries = 0 THEN 'no_attribution'
            WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN attributed_queries = 0 OR __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN attributed_credits * __CREDIT_PRICE__ >= :crit_usd THEN 'CRITICAL'
         WHEN attributed_credits * __CREDIT_PRICE__ >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY est_attributed_usd_list DESC NULLS LAST, queries DESC
