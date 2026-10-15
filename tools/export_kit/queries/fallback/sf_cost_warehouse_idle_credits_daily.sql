-- query_id: sf_cost_warehouse_idle_credits_daily
-- shims: WAREHOUSE_METERING_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY
-- fallback_note: warehouse credits for 6 months at most; adaptive warehouses left out; the warehouse name stands in for its id; no per-query attribution
-- needs: MONITOR USAGE
WITH h AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         DATE(start_time) AS usage_date, HOUR(start_time) AS hour_of_day, DAYOFWEEKISO(start_time) AS day_of_week,
         SUM(credits_used_compute) AS compute_credits,
         SUM(credits_attributed_compute_queries) AS query_credits,
         -- An hour newer than the 8 h attribution lag or with a NULL split (adaptive) is not idle evidence.
         BOOLOR_AGG(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL) AS attributed
  FROM __SHIM_WAREHOUSE_METERING_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), DATE(start_time), HOUR(start_time), DAYOFWEEKISO(start_time)
  HAVING SUM(credits_used_compute) > 0
),
s AS (
  SELECT h.*, IFF(attributed, GREATEST(compute_credits - COALESCE(query_credits, 0), 0), NULL) AS idle_credits,
         IFF(attributed, compute_credits, 0) AS attributed_compute_credits
  FROM h
),
-- The status is judged on the whole warehouse day and repeated on its hour rows.
d AS (
  SELECT s.*,
         COUNT(*) OVER (PARTITION BY warehouse_id, usage_date) AS day_billed_hours,
         COUNT_IF(attributed) OVER (PARTITION BY warehouse_id, usage_date) AS day_attributed_hours,
         SUM(idle_credits) OVER (PARTITION BY warehouse_id, usage_date) AS day_idle_credits,
         SUM(attributed_compute_credits) OVER (PARTITION BY warehouse_id, usage_date) AS day_attributed_compute_credits
  FROM s
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_name, warehouse_id,
       usage_date, hour_of_day, day_of_week, 1 AS billed_hours, compute_credits, query_credits, idle_credits,
       100 * idle_credits / NULLIF(compute_credits, 0) AS idle_pct,
       day_billed_hours, day_idle_credits,
       100 * day_idle_credits / NULLIF(day_attributed_compute_credits, 0) AS day_idle_pct,
       compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list,
       idle_credits * __CREDIT_PRICE__ AS est_idle_context_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN day_attributed_hours = 0 THEN 'no_query_attribution' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR day_attributed_hours = 0 THEN 'NOT_ASSESSED'
         WHEN day_idle_credits * __CREDIT_PRICE__ >= :crit_idle_usd THEN 'CRITICAL'
         WHEN day_idle_credits * __CREDIT_PRICE__ >= :warn_idle_usd THEN 'WARN'
         WHEN 100 * day_idle_credits / NULLIF(day_attributed_compute_credits, 0) >= :warn_idle_pct
              AND day_idle_credits * __CREDIT_PRICE__ >= :warn_idle_usd / 10 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM d
ORDER BY day_idle_credits DESC NULLS LAST, warehouse_id, usage_date, hour_of_day
