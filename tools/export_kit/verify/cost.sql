-- Test queries: Cost, Waste & savings and Overview. Read-only (SELECT and WITH only); paste one at a time
-- into a worksheet. Each recomputes a figure the app shows, straight from SNOWFLAKE.ACCOUNT_USAGE.
-- Change the numbers in the p CTE: days = the window you picked in the app, end_date = the export date
-- (the app counts up to midnight of that day; today is left out), usd_per_credit = your price,
-- usd_per_tb_month = your storage price.

-- 1. Spend in the window, the one total every page uses (Overview "Spend"; check
--    cost_dollarized_by_service_day): credits billed after the cloud services adjustment, plus storage
--    (TB-days) and data transfer out of the region. Archive storage has no list price and is left out.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit, 23.00 AS usd_per_tb_month)
SELECT 'credits billed' AS line, ROUND(SUM(credits_billed), 2) AS quantity, ROUND(SUM(credits_billed) * MAX(p.usd_per_credit), 2) AS usd
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, p
WHERE usage_date >= DATEADD(day, -p.days, p.end_date) AND usage_date < p.end_date
UNION ALL
SELECT 'storage TB-days', ROUND(SUM((COALESCE(storage_bytes, 0) + COALESCE(stage_bytes, 0) + COALESCE(failsafe_bytes, 0)
                                     + COALESCE(hybrid_table_storage_bytes, 0)) / POWER(1024, 4)), 2),
       ROUND(SUM((COALESCE(storage_bytes, 0) + COALESCE(stage_bytes, 0) + COALESCE(failsafe_bytes, 0)
                  + COALESCE(hybrid_table_storage_bytes, 0)) / POWER(1024, 4)) * MAX(p.usd_per_tb_month) / 30.4, 2)
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE, p
WHERE usage_date >= DATEADD(day, -p.days, p.end_date) AND usage_date < p.end_date
UNION ALL
-- BYTES_TRANSFERRED is read as text, the way the app reads it
SELECT 'data transfer TB', ROUND(SUM(TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred))) / POWER(1024, 4), 3),
       ROUND(SUM(TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred)) / POWER(1024, 4) * IFF(UPPER(target_cloud) = UPPER(source_cloud), 20, 90)), 2)
FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date;

-- 2. Spend by service, this window and the one before (Cost > Trend; checks cost_period_over_period and
--    cost_chargeback_by_service).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit)
SELECT service_type,
       ROUND(SUM(IFF(usage_date >= DATEADD(day, -p.days, p.end_date), credits_billed, 0)) * MAX(p.usd_per_credit), 2) AS usd_now,
       ROUND(SUM(IFF(usage_date < DATEADD(day, -p.days, p.end_date), credits_billed, 0)) * MAX(p.usd_per_credit), 2) AS usd_before
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, p
WHERE usage_date >= DATEADD(day, -2 * p.days, p.end_date) AND usage_date < p.end_date
GROUP BY service_type
ORDER BY usd_now DESC;

-- 3. Warehouse spend per warehouse, billed (Cost > Chargeback; check cost_chargeback_by_warehouse). Cloud
--    services are priced after the warehouse service's own daily 10% adjustment, so the total equals the
--    WAREHOUSE_METERING line of query 2.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit),
r AS (
  SELECT usage_date, GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
                     / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE service_type = 'WAREHOUSE_METERING'
  GROUP BY usage_date
)
SELECT MAX(m.warehouse_name) || ' (' || m.warehouse_id || ')' AS warehouse,
       ROUND(SUM(m.credits_used_compute + m.credits_used_cloud_services * COALESCE(r.billed_ratio, 1)), 2) AS credits,
       ROUND(SUM(m.credits_used_compute + m.credits_used_cloud_services * COALESCE(r.billed_ratio, 1)) * MAX(p.usd_per_credit), 2) AS usd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
LEFT JOIN r ON r.usage_date = CAST(m.start_time AS DATE), p
WHERE m.start_time >= DATEADD(day, -p.days, p.end_date) AND m.start_time < p.end_date
GROUP BY m.warehouse_id
ORDER BY credits DESC;

-- 4. Attributed query credits per role (Cost > Chargeback; check sf_chg_by_role). Every attributed query
--    counts, also one with no QUERY_HISTORY row.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
a AS (
  SELECT query_id, SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
  GROUP BY query_id
)
SELECT COALESCE(q.role_name, IFF(q.query_id IS NULL, '(no query history row)', '(none)')) AS role_name,
       COUNT(*) AS queries, ROUND(SUM(a.credits), 2) AS attributed_credits
FROM a CROSS JOIN p
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  ON q.query_id = a.query_id AND q.start_time >= DATEADD(day, -p.days - 1, p.end_date) AND q.start_time < p.end_date
GROUP BY 1
ORDER BY attributed_credits DESC;

-- 5. Month to date and last month (Cost > Contract; checks sf_cost_month_end_forecast and
--    cost_monthly_actuals), credits billed only; storage and transfer are added on the page.
WITH p AS (SELECT CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit)
SELECT DATE_TRUNC('month', usage_date) AS month, ROUND(SUM(credits_billed), 2) AS credits,
       ROUND(SUM(credits_billed) * MAX(p.usd_per_credit), 2) AS usd
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, p
WHERE usage_date >= DATEADD(month, -1, DATE_TRUNC('month', p.end_date)) AND usage_date < p.end_date
GROUP BY 1
ORDER BY 1;

-- 6. Cloud services billed per day after the 10% allowance (Cost; check sf_cost_cloud_services_billed).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT usage_date, ROUND(SUM(credits_used_cloud_services), 2) AS cloud_services,
       ROUND(GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0), 2) AS billed
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, p
WHERE usage_date >= DATEADD(day, -p.days, p.end_date) AND usage_date < p.end_date
GROUP BY usage_date
ORDER BY billed DESC;
