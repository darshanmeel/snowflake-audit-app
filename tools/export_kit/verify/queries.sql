-- Test queries: Queries. Read-only (SELECT and WITH only); paste one at a time into a worksheet.
-- Each recomputes a figure the app shows, straight from SNOWFLAKE.ACCOUNT_USAGE, so you can compare.
-- Change the numbers in the p CTE: days = the window you picked in the app, end_date = the export date
-- (the app counts up to midnight of that day; today is left out), usd_per_credit = your price.
-- Query attribution leaves out idle time and queries under about 100 ms and lags up to 8 hours.

-- 1. Attributed compute by statement type, query acceleration included (Queries > Heavy;
--    check sf_query_cost_by_statement_type). The "Top 10 statement shapes" tile divides by this total.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit),
a AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
  GROUP BY query_id
)
SELECT COALESCE(NULLIF(TRIM(q.query_type), ''), '(unknown)') AS statement_type, COUNT(*) AS queries,
       ROUND(SUM(COALESCE(a.credits, 0)), 2) AS attributed_credits,
       ROUND(SUM(COALESCE(a.credits, 0)) * MAX(p.usd_per_credit), 2) AS attributed_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
LEFT JOIN a ON a.query_id = q.query_id, p
WHERE q.start_time >= DATEADD(day, -p.days, p.end_date) AND q.start_time < p.end_date
GROUP BY 1
ORDER BY attributed_credits DESC;

-- 2. The costliest statement shapes (Queries > Heavy, Query patterns; check query_top_by_cost).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit),
a AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
  GROUP BY query_id
)
SELECT q.warehouse_id, q.query_type, COALESCE(q.query_parameterized_hash, '(ad-hoc) ' || q.user_name) AS shape,
       COUNT(*) AS runs, ROUND(SUM(COALESCE(a.credits, 0)) * MAX(p.usd_per_credit), 2) AS usd
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
LEFT JOIN a ON a.query_id = q.query_id, p
WHERE q.start_time >= DATEADD(day, -p.days, p.end_date) AND q.start_time < p.end_date AND q.warehouse_id IS NOT NULL
GROUP BY 1, 2, 3
ORDER BY usd DESC
LIMIT 10;

-- 3. Failed and cancelled queries, and their top user per warehouse (Queries > Failures;
--    checks query_failed_queries_daily and cost_failed_statement_waste). The page's three totals:
--    all failed or cancelled; those on a warehouse; those failed with an error code. A cancel is a FAIL
--    with error 604.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT COUNT_IF(execution_status IN ('FAIL', 'INCIDENT')) AS failed_or_cancelled,
       COUNT_IF(execution_status IN ('FAIL', 'INCIDENT') AND error_code = 604) AS cancelled,
       COUNT_IF(execution_status IN ('FAIL', 'INCIDENT') AND warehouse_id IS NOT NULL) AS on_warehouses,
       -- the "Where failures land" table: retried failures are under retries, and only warehouses with a failure
       COUNT_IF(execution_status = 'FAIL' AND warehouse_id IS NOT NULL
                AND (error_code = 604 OR COALESCE(query_retry_time, 0) = 0)) AS in_where_table_upper_bound,
       COUNT_IF(execution_status = 'FAIL' AND error_code IS NOT NULL AND error_code <> 604) AS failed_with_error_code,
       COUNT(*) AS all_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date;

WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
f AS (
  SELECT warehouse_id, MAX(warehouse_name) OVER (PARTITION BY warehouse_id) AS warehouse_name, user_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
    AND warehouse_id IS NOT NULL AND execution_status IN ('FAIL', 'INCIDENT')
)
SELECT warehouse_name || ' (' || warehouse_id || ')' AS warehouse, COUNT(*) AS failed_or_cancelled,
       MODE(user_name) AS top_user
FROM f
GROUP BY warehouse_id, warehouse_name
ORDER BY failed_or_cancelled DESC;

-- 4. Spill per warehouse and day, local and remote apart (Queries > Efficiency; check
--    query_local_spillage). GB = 1024^3 bytes; a day flags at 1 GB (Warn) and 10 GB (Critical).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT DATE(start_time) AS day, MAX(warehouse_name) || ' (' || warehouse_id || ')' AS warehouse,
       COUNT(*) AS spilling_queries,
       ROUND(SUM(COALESCE(bytes_spilled_to_local_storage, 0)) / POWER(1024, 3), 2) AS local_gb,
       ROUND(SUM(COALESCE(bytes_spilled_to_remote_storage, 0)) / POWER(1024, 3), 2) AS remote_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
  AND COALESCE(bytes_spilled_to_local_storage, 0) + COALESCE(bytes_spilled_to_remote_storage, 0) > 0
GROUP BY 1, warehouse_id
ORDER BY local_gb + remote_gb DESC
LIMIT 50;

-- 5. Warehouse compute whose session is not in SESSIONS (Queries > By source & team, "Compute with no
--    client record"; check sf_query_by_client_application). It is a gap in the data, never judged.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
s AS (
  SELECT session_id FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, p
  WHERE created_on >= DATEADD(day, -p.days - 30, p.end_date)
),
a AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
  GROUP BY query_id
)
SELECT s.session_id IS NULL AS no_session_record, COUNT(*) AS queries, ROUND(SUM(COALESCE(a.credits, 0)), 2) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
LEFT JOIN s ON s.session_id = q.session_id
LEFT JOIN a ON a.query_id = q.query_id, p
WHERE q.start_time >= DATEADD(day, -p.days, p.end_date) AND q.start_time < p.end_date AND q.warehouse_id IS NOT NULL
GROUP BY 1;

-- 6. Long-running statements and timeouts per warehouse (Queries > Heavy; check sf_query_long_running).
--    Error 000630 is a statement timeout.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT MAX(warehouse_name) || ' (' || warehouse_id || ')' AS warehouse,
       COUNT(*) AS runs_over_1h, ROUND(MAX(total_elapsed_time) / 3600000, 1) AS longest_hours,
       SUM(IFF(error_code = '000630', 1, 0)) AS timed_out
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
  AND total_elapsed_time >= 3600000
GROUP BY warehouse_id
ORDER BY longest_hours DESC;

-- 7. Queued time per warehouse and day (Queries > Waiting; check query_queuing_waits): a day flags at
--    60 s (Warn) and 600 s (Critical) of queueing.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT DATE(start_time) AS day, MAX(warehouse_name) || ' (' || warehouse_id || ')' AS warehouse,
       ROUND(SUM(COALESCE(queued_overload_time, 0) + COALESCE(queued_provisioning_time, 0)) / 1000) AS queued_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date AND warehouse_id IS NOT NULL
GROUP BY 1, warehouse_id
HAVING queued_seconds >= 60
ORDER BY queued_seconds DESC;
