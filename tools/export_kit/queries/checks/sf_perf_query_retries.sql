-- query_id: sf_perf_query_retries
-- title: Execution time lost to query retries, per warehouse
-- domain: performance   tier: standard
-- entity: warehouses = warehouse
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_retry_hours (default 1) retry hours: least a warehouse needs before it can flag;
--   :warn_retry_pct (default 5) retry pct of execution time: at or above this the row reads WARN;
--   :crit_retry_pct (default 20) retry pct: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. retry_hours is execution time spent re-running queries after
--   actionable errors (out of memory and similar); retry_pct is that over the warehouse's total query
--   execution time. est_wasted_usd_list is an estimate: each day's retry share (capped at 100) times that
--   day's query-attributed compute credits (idle time is left out: sf_wh_idle_minutes counts it), priced once. It is possible waste, not a bill line. A query that retried and
--   then failed is counted here only: cost_failed_statement_waste leaves retried queries out, so no
--   query is possible waste in both.
-- healthy: status = OK when retries are a small part of execution time or of small size.
-- investigate_if: WARN when retry_pct is >= warn_retry_pct with at least min_retry_hours of retries,
--   CRITICAL at crit_retry_pct.
-- actions: 1) look at the queries with retries on that warehouse for big joins or sorts (free); 2) fix
--   the SQL or split the job (config); 3) move the heavy queries to a larger warehouse (spend).
-- next: none
-- empty_if: no_activity, role_cannot_see
-- caveats: retry time is a share of query time, not of warehouse time (concurrent queries are not in it; idle time
--   is left out on purpose, the attribution column is NULL on adaptive warehouses), so the dollar figure is an estimate. Non-actionable fault handling time is not
--   counted. The cause is stored as a coarse class only (memory or other), never the error text.
--   QUERY_HISTORY lags up to 45 min and metering up to 3 h.
WITH q AS (
  SELECT warehouse_id, DATE(start_time) AS usage_date,
         MAX(warehouse_name) AS warehouse_name,
         COUNT(*) AS queries,
         COUNT_IF(query_retry_time > 0) AS retry_queries,
         COUNT_IF(query_retry_time > 0 AND query_retry_cause ILIKE '%memory%') AS memory_retry_queries,
         SUM(COALESCE(query_retry_time, 0)) AS retry_ms,
         SUM(COALESCE(execution_time, 0)) AS exec_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
  GROUP BY warehouse_id, DATE(start_time)
),
m AS (
  SELECT warehouse_id, DATE(start_time) AS usage_date, SUM(credits_attributed_compute_queries) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY warehouse_id, DATE(start_time)
),
d AS (
  SELECT q.*, m.compute_credits,
         LEAST(1, q.retry_ms / NULLIF(q.exec_ms, 0)) * m.compute_credits AS retry_credits
  FROM q LEFT JOIN m ON m.warehouse_id = q.warehouse_id AND m.usage_date = q.usage_date
),
w AS (
  SELECT warehouse_id, MAX(warehouse_name) AS warehouse_name,
         SUM(queries) AS queries, SUM(retry_queries) AS retry_queries,
         SUM(memory_retry_queries) AS memory_retry_queries,
         SUM(retry_ms) / 3600000.0 AS retry_hours, SUM(exec_ms) / 3600000.0 AS exec_hours,
         100 * SUM(retry_ms) / NULLIF(SUM(exec_ms), 0) AS retry_pct,
         SUM(COALESCE(retry_credits, 0)) AS est_retry_credits,
         COUNT_IF(retry_ms > 0 AND compute_credits IS NULL) AS retry_days_without_metering
  FROM d
  GROUP BY warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       COALESCE(warehouse_name, 'unknown') || ' (' || TO_VARCHAR(warehouse_id) || ')' AS warehouse,
       queries, retry_queries, memory_retry_queries, retry_queries - memory_retry_queries AS other_retry_queries,
       retry_hours, exec_hours, ROUND(retry_pct, 2) AS retry_pct,
       est_retry_credits, retry_days_without_metering,
       est_retry_credits * __CREDIT_PRICE__ AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE
         WHEN retry_hours < :min_retry_hours THEN 'OK'
         WHEN retry_pct >= :crit_retry_pct THEN 'CRITICAL'
         WHEN retry_pct >= :warn_retry_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM w
ORDER BY retry_hours DESC NULLS LAST
