-- query_id: sf_share_reader_accounts
-- shims: 
-- reads: INFORMATION_SCHEMA table functions 
-- fallback_note: 
-- pre: SHOW MANAGED ACCOUNTS
WITH ma_show AS (
  SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
-- SHOW returns account_name/account_locator; the docs' example still shows name/locator, so read either.
ma AS (
  SELECT COALESCE(o:"account_name", o:"name")::VARCHAR AS reader_account_name,
         COALESCE(o:"account_locator", o:"locator")::VARCHAR AS account_locator, "cloud" AS cloud,
         "region" AS region, CAST("created_on" AS TIMESTAMP_LTZ) AS created_on, "comment" AS comment,
         LOWER(TO_VARCHAR("is_reader")) = 'true' AS is_reader
  FROM (SELECT s.*, OBJECT_CONSTRUCT(*) AS o FROM ma_show s)
),
d AS (
  -- Per reader account and day: compute plus the cloud services above 10% of that day's compute (the
  -- daily adjustment; there is no reader METERING_DAILY_HISTORY, so it is rebuilt from the hourly rows).
  SELECT reader_account_name, DATE(start_time) AS usage_date,
         SUM(credits_used_compute) AS compute_credits,
         SUM(credits_used_cloud_services) AS cs_credits
  FROM SNOWFLAKE.READER_ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
w AS (
  SELECT reader_account_name, COUNT(DISTINCT warehouse_name) AS warehouses,
         LISTAGG(DISTINCT warehouse_name, ', ') WITHIN GROUP (ORDER BY warehouse_name) AS warehouse_names
  FROM SNOWFLAKE.READER_ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
m AS (
  SELECT d.reader_account_name,
         SUM(d.compute_credits + GREATEST(d.cs_credits - 0.1 * d.compute_credits, 0)) AS credits,
         MAX(w.warehouses) AS warehouses, MAX(w.warehouse_names) AS warehouse_names
  FROM d JOIN w ON w.reader_account_name = d.reader_account_name
  GROUP BY 1
),
l AS (
  SELECT reader_account_name, COUNT_IF(is_success = 'YES') AS successful_logins,
         COUNT(DISTINCT IFF(is_success = 'YES', user_name, NULL)) AS login_users,
         MAX(IFF(is_success = 'YES', event_timestamp, NULL)) AS last_login
  FROM SNOWFLAKE.READER_ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
  GROUP BY 1
),
rm AS (
  SELECT reader_account_name, COUNT(*) AS resource_monitors
  FROM SNOWFLAKE.READER_ACCOUNT_USAGE.RESOURCE_MONITORS
  GROUP BY 1
),
names AS (
  SELECT reader_account_name FROM ma WHERE is_reader
  UNION SELECT reader_account_name FROM m
),
j AS (
  SELECT n.reader_account_name, ma.account_locator, ma.cloud, ma.region, ma.created_on, ma.comment,
         ma.reader_account_name IS NOT NULL AS is_live,
         COALESCE(m.credits, 0) AS credits, COALESCE(m.warehouses, 0) AS warehouses, m.warehouse_names,
         COALESCE(l.successful_logins, 0) AS successful_logins, COALESCE(l.login_users, 0) AS login_users,
         l.last_login, COALESCE(rm.resource_monitors, 0) AS resource_monitors
  FROM names n
  LEFT JOIN ma ON ma.reader_account_name = n.reader_account_name
  LEFT JOIN m ON m.reader_account_name = n.reader_account_name
  LEFT JOIN l ON l.reader_account_name = n.reader_account_name
  LEFT JOIN rm ON rm.reader_account_name = n.reader_account_name
),
scored AS (
  SELECT j.*, credits * __CREDIT_PRICE__ AS usd,
         (is_live AND successful_logins = 0
          AND COALESCE(created_on, '1970-01-01'::TIMESTAMP_LTZ) < DATEADD(day, -:period_days, __AS_OF_DATE__)) AS unused
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       reader_account_name, account_locator, cloud, region, created_on, comment, is_live,
       warehouses, warehouse_names, credits AS credits_used, resource_monitors,
       successful_logins, login_users, last_login,
       usd AS est_reader_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(unused, 'no sign-in in ' || :period_days || ' days', NULL),
         IFF(credits > 0 AND resource_monitors = 0, 'spends with no resource monitor', NULL),
         IFF(usd >= :warn_usd, ROUND(usd) || ' USD billed to this account', NULL)), '; ') AS reasons,
       CASE WHEN __CREDIT_PRICE__ IS NULL AND credits > 0 THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN usd >= :crit_usd OR (usd >= :warn_usd AND resource_monitors = 0) THEN 'CRITICAL'
         WHEN usd >= :warn_usd OR (credits > 0 AND resource_monitors = 0) OR unused THEN 'WARN'
         WHEN __CREDIT_PRICE__ IS NULL AND credits > 0 THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, credits DESC
