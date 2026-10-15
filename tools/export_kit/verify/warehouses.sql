-- Test queries: Warehouses. Read-only (SELECT and WITH only); paste one at a time into a worksheet.
-- Each recomputes a figure the app shows, straight from SNOWFLAKE.ACCOUNT_USAGE, so you can compare.
-- Change the numbers in the p CTE: days = the window you picked in the app, end_date = the export date
-- (the app counts up to midnight of that day; today is left out), usd_per_credit = your price.

-- 1. Idle credits per warehouse (Warehouses > Idle & settings; check sf_wh_idle_minutes).
--    Idle = compute billed in settled hours (older than 8 h) minus what queries were attributed.
--    The auto-suspend saving (sf_wh_auto_suspend_tuning) is never more than idle_credits here.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit)
SELECT MAX(m.warehouse_name) || ' (' || m.warehouse_id || ')' AS warehouse,
       ROUND(SUM(m.credits_used_compute), 2) AS compute_credits,
       ROUND(GREATEST(SUM(IFF(m.start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP())
                              AND m.credits_attributed_compute_queries IS NOT NULL, m.credits_used_compute, 0))
                    - SUM(IFF(m.start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()),
                              m.credits_attributed_compute_queries, 0)), 0), 2) AS idle_credits,
       ROUND(idle_credits * MAX(p.usd_per_credit), 2) AS idle_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m, p
WHERE m.start_time >= DATEADD(day, -p.days, p.end_date) AND m.start_time < p.end_date
GROUP BY m.warehouse_id
ORDER BY idle_credits DESC;

-- 2. Multi-cluster spin-ups per warehouse (Warehouses > Load; check sf_wh_multicluster_scaling).
--    A spin-up writes a STARTED and a COMPLETED row; it is counted once.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT MAX(warehouse_name) || ' (' || warehouse_id || ')' AS warehouse,
       COUNT_IF(event_name = 'RESUME_CLUSTER' AND event_reason = 'MULTICLUSTER_SPINUP'
                AND COALESCE(event_state, 'STARTED') = 'STARTED') AS spinups
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY, p
WHERE timestamp >= DATEADD(day, -p.days, p.end_date) AND timestamp < p.end_date
GROUP BY warehouse_id
HAVING spinups > 0
ORDER BY spinups DESC;

-- 3. Warehouses that billed compute but have no load history (they read Not assessed on Load,
--    never "load 0"; check sf_wh_load_utilization).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
m AS (
  SELECT warehouse_id, MAX(warehouse_name) AS warehouse_name, SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
  GROUP BY warehouse_id
),
l AS (
  SELECT DISTINCT warehouse_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
)
SELECT m.warehouse_name || ' (' || m.warehouse_id || ')' AS warehouse, ROUND(m.compute_credits, 2) AS compute_credits
FROM m LEFT JOIN l ON l.warehouse_id = m.warehouse_id
WHERE l.warehouse_id IS NULL AND m.compute_credits > 0
ORDER BY m.compute_credits DESC;

-- 4. Query acceleration credits per warehouse (Warehouses > Load; check sf_wh_query_acceleration_spend,
--    shown as Warn at most because it is spend, not waste).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit)
SELECT MAX(warehouse_name) || ' (' || warehouse_id || ')' AS warehouse,
       ROUND(SUM(credits_used), 2) AS qas_credits, ROUND(SUM(credits_used) * MAX(p.usd_per_credit), 2) AS qas_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
GROUP BY warehouse_id
ORDER BY qas_credits DESC;
