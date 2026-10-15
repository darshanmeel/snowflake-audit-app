-- Test queries: AI & apps. Read-only (SELECT and WITH only); paste one at a time into a worksheet. Each
-- recomputes a figure the app shows, straight from SNOWFLAKE.ACCOUNT_USAGE. Prompts and responses are
-- never read. Change the numbers in the p CTE: days = the window you picked in the app, end_date = the
-- export date, usd_per_credit = your price.

-- 1. AI services and container services on the bill (AI & apps; check sf_ai_services_spend_trend).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit)
--    Live accounts bill AI as AI_INFERENCE and Snowsight Cortex Code as SNOWFLAKE_COCO_SNOWSIGHT; the app
--    shows those as AI_SERVICES and CORTEX_CODE_SNOWSIGHT.
SELECT service_type, ROUND(SUM(credits_billed), 2) AS credits, ROUND(SUM(credits_billed) * MAX(p.usd_per_credit), 2) AS usd
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, p
WHERE usage_date >= DATEADD(day, -p.days, p.end_date) AND usage_date < p.end_date
  AND service_type IN ('AI_SERVICES', 'AI_INFERENCE', 'SNOWPARK_CONTAINER_SERVICES', 'CORTEX_CODE_CLI',
                       'CORTEX_CODE_SNOWSIGHT', 'SNOWFLAKE_COCO_SNOWSIGHT')
GROUP BY service_type
ORDER BY credits DESC;

-- 2. AI credits by feature (AI & apps; check sf_ai_spend_by_feature_reconciled). Their sum against the
--    AI_SERVICES (or AI_INFERENCE) line of query 1 is the unexplained part (the check leaves out the last few days, which settle late).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT 'AI functions' AS feature, ROUND(SUM(credits), 2) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
UNION ALL
SELECT 'Analyst', ROUND(SUM(credits), 2) FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
UNION ALL
SELECT 'Search', ROUND(SUM(credits), 2) FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY, p
WHERE usage_date >= DATEADD(day, -p.days, p.end_date) AND usage_date < p.end_date
UNION ALL
SELECT 'Agents', ROUND(SUM(token_credits), 2) FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date;

-- 3. AI function credits per user (AI & apps; check sf_ai_functions_spend_by_user). The view records the
--    user id since 16 Feb 2026; older rows have none.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit),
u AS (SELECT user_id, MAX(name) AS user_name FROM SNOWFLAKE.ACCOUNT_USAGE.USERS GROUP BY user_id)
SELECT COALESCE(u.user_name, '(user not recorded)') || COALESCE(' (' || TO_VARCHAR(f.user_id) || ')', '') AS user_name,
       ROUND(SUM(f.credits), 2) AS credits, ROUND(SUM(f.credits) * MAX(p.usd_per_credit), 2) AS usd
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY f
CROSS JOIN p
LEFT JOIN u ON TO_VARCHAR(u.user_id) = TO_VARCHAR(f.user_id)
WHERE f.start_time >= DATEADD(day, -p.days, p.end_date) AND f.start_time < p.end_date
GROUP BY 1
ORDER BY credits DESC;

-- 4. Container services credits per compute pool (AI & apps; check sf_ai_snowpark_container_services).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit)
SELECT compute_pool_name, ROUND(SUM(credits_used), 2) AS credits, ROUND(SUM(credits_used) * MAX(p.usd_per_credit), 2) AS usd
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
GROUP BY compute_pool_name
ORDER BY credits DESC;
