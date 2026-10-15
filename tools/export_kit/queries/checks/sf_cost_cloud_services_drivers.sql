-- query_id: sf_cost_cloud_services_drivers
-- title: What drives cloud services credits
-- domain: cost   tier: standard
-- money: est_billed_share_usd_list
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_share_pct (default 20) share pct: at or above this the row reads WARN; :crit_share_pct
--   (default 50) share pct: at or above this the row reads CRITICAL; :min_driver_usd (default 10)
--   driver usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse x user x query type that used cloud services credits.
--   share_of_cloud_services_pct is its part of the account's cloud services use in the window;
--   est_billed_share_usd_list is that share applied to what was actually billed above the free 10%.
--   warehouse_name '(none)' = statements that ran no warehouse (SHOW, DESCRIBE, metadata, cached).
-- healthy: status = OK when the account pays nothing for cloud services, or no single driver is a
--   large, costly share of it.
-- investigate_if: WARN when a driver is >= warn_share_pct of cloud services and its share of the billed
--   amount is >= min_driver_usd; CRITICAL when the share is >= crit_share_pct.
-- actions: 1) find the tool or user behind the top row and ask what it polls (free); 2) replace
--   frequent SHOW/DESCRIBE/INFORMATION_SCHEMA polling with ACCOUNT_USAGE reads, batch single-row DML,
--   simplify queries that compile for seconds (config); 3) move tiny statements onto a schedule that
--   runs fewer of them (spend).
-- next: none
-- caveats: QUERY_HISTORY credits are before the daily 10% adjustment, so billed dollars per driver are
--   a proportional estimate. Only queries in QUERY_HISTORY are seen (not serverless features).
WITH q AS (
  SELECT COALESCE(warehouse_name, '(none)') AS warehouse_name,
         COALESCE(TO_VARCHAR(warehouse_id), '(none)') AS warehouse_id,
         user_name, query_type,
         COUNT(*) AS queries,
         SUM(credits_used_cloud_services) AS cs_credits,
         AVG(compilation_time) AS avg_compilation_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND credits_used_cloud_services > 0
  GROUP BY 1, 2, 3, 4
),
acct AS (
  SELECT SUM(credits_used_cloud_services) AS cs_used,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0) AS cs_billed
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
s AS (
  SELECT q.*, acct.cs_billed,
         100 * q.cs_credits / NULLIF(SUM(q.cs_credits) OVER (), 0) AS share_pct,
         acct.cs_billed * q.cs_credits / NULLIF(SUM(q.cs_credits) OVER (), 0) AS billed_share_credits
  FROM q CROSS JOIN acct
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_name, warehouse_id,
       user_name, query_type, queries, cs_credits AS cloud_services_credits, avg_compilation_ms,
       share_pct AS share_of_cloud_services_pct,
       billed_share_credits AS billed_share_credits,
       billed_share_credits * __CREDIT_PRICE__ AS est_billed_share_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cs_billed <= 0 OR billed_share_credits * __CREDIT_PRICE__ < :min_driver_usd THEN 'OK'
         WHEN share_pct >= :crit_share_pct THEN 'CRITICAL'
         WHEN share_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY cloud_services_credits DESC
