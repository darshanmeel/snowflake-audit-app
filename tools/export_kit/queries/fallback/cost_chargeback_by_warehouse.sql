-- query_id: cost_chargeback_by_warehouse
-- shims: METERING_DAILY_HISTORY, WAREHOUSE_METERING_HISTORY, QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY, QUERY_HISTORY
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule; warehouse credits for 6 months at most; adaptive warehouses left out; the warehouse name stands in for its id; no per-query attribution; queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
-- needs: MONITOR USAGE
WITH -- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM __SHIM_METERING_DAILY_HISTORY__
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
wh AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), (credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1)), 0)) AS cur_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), (credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1)), 0)) AS prev_credits,
         COUNT_IF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND credits_used > 0) AS billed_hours
  FROM __SHIM_WAREHOUSE_METERING_HISTORY__
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
q AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, COUNT(*) AS queries
  FROM __SHIM_QUERY_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
  GROUP BY 1
),
cov AS (
  -- Earliest day with any warehouse usage: a young account has no honest previous window.
  SELECT MIN(CAST(start_time AS DATE)) AS first_usage_date
  FROM __SHIM_WAREHOUSE_METERING_HISTORY__
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__ AND credits_used > 0
),
scored AS (
  SELECT w.warehouse_id, w.billed_hours, COALESCE(q.queries, 0) AS queries, w.cur_credits,
         w.cur_credits * __CREDIT_PRICE__ AS usd, w.prev_credits * __CREDIT_PRICE__ AS prev_usd,
         CASE
           WHEN c.first_usage_date IS NULL OR c.first_usage_date > DATEADD(day, -2 * :period_days, __AS_OF_DATE__)
             THEN 'previous_window_not_covered'
           WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
         END AS reason
  FROM wh w LEFT JOIN q ON q.warehouse_id = w.warehouse_id CROSS JOIN cov c
),
judged AS (
  SELECT s.*,
         CASE
           WHEN reason IS NOT NULL THEN 'NOT_ASSESSED'
           WHEN GREATEST(usd, prev_usd) < :min_spend_usd THEN 'OK'
           WHEN prev_usd = 0 THEN 'WARN'
           WHEN 100 * (usd - prev_usd) / prev_usd >= :crit_increase_pct THEN 'CRITICAL'
           WHEN 100 * (usd - prev_usd) / prev_usd >= :warn_increase_pct THEN 'WARN'
           ELSE 'OK'
         END AS st
  FROM scored s
),
ranked AS (
  SELECT j.*, ROW_NUMBER() OVER (PARTITION BY st ORDER BY cur_credits DESC) AS rn
  FROM judged j
),
-- Status is judged per warehouse first; only OK and NOT_ASSESSED rows past :top_n are pooled.
keyed AS (
  SELECT r.*, IFF(rn <= :top_n OR st IN ('WARN', 'CRITICAL'), warehouse_id, 'other') AS grp_key
  FROM ranked r
),
-- Group on plain columns only: Snowflake rejects a derived flag that wraps the window column.
folded AS (
  SELECT grp_key AS warehouse_id, grp_key = 'other' AS is_other, st,
         COUNT(*) AS pooled_count, SUM(billed_hours) AS billed_hours, SUM(queries) AS queries,
         SUM(usd) AS usd, SUM(prev_usd) AS prev_usd,
         IFF(grp_key = 'other', NULL, MAX(reason)) AS reason
  FROM keyed
  GROUP BY grp_key, st
),
total AS (SELECT SUM(usd) AS usd FROM folded)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, f.warehouse_id, f.is_other,
       f.pooled_count, f.billed_hours, f.queries,
       IFF(f.queries > 0, 1000 * f.usd / f.queries, NULL) AS usd_per_1000_queries,
       f.usd AS usd_list, 100 * f.usd / NULLIF(t.usd, 0) AS share_of_total_pct,
       f.prev_usd AS prev_usd_list, f.usd - f.prev_usd AS change_usd_list,
       IFF(f.prev_usd > 0, 100 * (f.usd - f.prev_usd) / f.prev_usd, NULL) AS change_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       f.st AS status,
       f.reason AS not_assessed_reason
FROM folded f CROSS JOIN total t
ORDER BY f.is_other, f.usd DESC
