-- query_id: cost_by_hour_of_day
-- shims: METERING_DAILY_HISTORY, WAREHOUSE_METERING_HISTORY, QUERY_HISTORY, TASK_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY, QUERY_HISTORY, TASK_HISTORY
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule; warehouse credits for 6 months at most; adaptive warehouses left out; the warehouse name stands in for its id; no per-query attribution; queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures; task runs for the last 7 days at most, up to 10,000 a day, only tasks this role owns or can monitor (MONITOR EXECUTION shows all)
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
slots AS (
  -- every weekday x hour slot, so an hour with no spend is a zero row and never a hole in the map
  SELECT d.weekday_num, d.weekday, h.hour_of_day
  FROM (VALUES (1, 'Mon'), (2, 'Tue'), (3, 'Wed'), (4, 'Thu'), (5, 'Fri'), (6, 'Sat'), (7, 'Sun')) AS d(weekday_num, weekday)
  CROSS JOIN (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12), (13), (14), (15), (16), (17), (18), (19), (20), (21), (22), (23)) AS h(hour_of_day)
),
spend AS (
  SELECT DAYOFWEEKISO(start_time) AS weekday_num, HOUR(start_time) AS hour_of_day,
         SUM((credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1))) * __CREDIT_PRICE__ AS usd
  FROM __SHIM_WAREHOUSE_METERING_HISTORY__
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
m AS (
  SELECT s.weekday, s.weekday_num, s.hour_of_day,
         IFF(__CREDIT_PRICE__ IS NULL, NULL, COALESCE(p.usd, 0)) AS usd
  FROM slots s LEFT JOIN spend p ON p.weekday_num = s.weekday_num AND p.hour_of_day = s.hour_of_day
),
qs AS (
  SELECT DAYOFWEEKISO(start_time) AS weekday_num, HOUR(start_time) AS hour_of_day, COUNT(*) AS n
  FROM __SHIM_QUERY_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
ts AS (
  SELECT DAYOFWEEKISO(query_start_time) AS weekday_num, HOUR(query_start_time) AS hour_of_day, COUNT(*) AS n
  FROM __SHIM_TASK_HISTORY__
  WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
total AS (SELECT SUM(usd) AS usd FROM m),
-- the flag is per hour-of-day (all weekdays and services together), not per weekday x hour slot
hod AS (SELECT hour_of_day, SUM(usd) AS usd FROM m GROUP BY 1)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, m.weekday, m.weekday_num,
       m.hour_of_day, 'UTC' AS hour_timezone, 'WAREHOUSE_METERING' AS billing_origin_product, m.usd AS usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       COALESCE(ts.n, 0) AS job_runs_active, COALESCE(qs.n, 0) AS queries_started,
       hd.usd AS hour_usd_list, t.usd AS window_usd_list,
       100 * hd.usd / NULLIF(t.usd, 0) AS share_of_window_spend,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', NULL) AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN 100 * hd.usd / NULLIF(t.usd, 0) >= :crit_hour_share_pct THEN 'CRITICAL'
         WHEN 100 * hd.usd / NULLIF(t.usd, 0) >= :warn_hour_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM m
CROSS JOIN total t
JOIN hod hd ON hd.hour_of_day = m.hour_of_day
LEFT JOIN qs ON qs.weekday_num = m.weekday_num AND qs.hour_of_day = m.hour_of_day
LEFT JOIN ts ON ts.weekday_num = m.weekday_num AND ts.hour_of_day = m.hour_of_day
ORDER BY m.weekday_num, m.hour_of_day
