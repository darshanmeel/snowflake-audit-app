-- query_id: sf_org_warehouse_spend_across_accounts
-- title: Top warehouses across the organization
-- domain: compute   tier: standard
-- money: est_cost
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY,
--   SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY, SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 50) top n: value this check uses; :settle_days (default 3) settle days: value
--   this check uses; :warn_share_pct (default 20) share pct: at or above this the row reads WARN;
--   :warn_growth_pct (default 50) growth pct: at or above this the row reads WARN; :crit_growth_pct
--   (default 150) growth pct: at or above this the row reads CRITICAL; :min_credits (default 100)
--   credits: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse in one account (account = account locator), the top_n by
--   credits in the window. est_cost = credits x that account's billed compute rate (invoice amount /
--   credits for the compute usage type) in the invoice currency; est_cost_usd_list uses the audit's
--   credit price. share_of_org_pct = share of all warehouse credits in the organization.
-- healthy: status = OK when a warehouse is flat and not a large share of the org.
-- investigate_if: WARN when a warehouse above min_credits grew >= warn_growth_pct, is new, or holds >=
--   warn_share_pct of org warehouse credits; the SQL marks it CRITICAL when it grew >= crit_growth_pct,
--   but the app shows a spend report as WARN at most.
-- actions: 1) run sf_wh_oversized, sf_wh_auto_suspend_tuning and query_top_by_cost in that account
--   (free); 2) right-size, shorten auto-suspend or split the workload (config); 3) add a resource
--   monitor with a hard cap on the top warehouses (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. Credits are compute plus billed cloud services (the daily 10% adjustment is taken off);
--   cloud_services_credits is shown before it. The CLOUD_SERVICES_ONLY row (cloud services with no
--   warehouse) is left out. The org view lags up to 24 hours.
WITH ratio AS (
  -- share of each account-day's cloud services credits that is billed after the daily 10% adjustment
  SELECT account_locator, usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -(2 * :period_days + :settle_days + 1), __AS_OF_DATE__)
    AND usage_date < __AS_OF_DATE__
  GROUP BY account_locator, usage_date
),
w AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(region) AS region,
         warehouse_id, MAX(warehouse_name) AS warehouse_name,
         SUM(IFF(start_time >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), b.billed, 0)) AS credits,
         SUM(IFF(start_time >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits_used_cloud_services, 0)) AS cloud_services_credits,
         SUM(IFF(start_time < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), b.billed, 0)) AS prev_credits,
         COUNT(DISTINCT IFF(start_time >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__) AND credits_used > 0,
                            DATE_TRUNC(day, start_time), NULL)) AS active_days
  FROM (SELECT m.*, m.credits_used_compute + m.credits_used_cloud_services * COALESCE(r.billed_ratio, 1) AS billed
        FROM SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY m
        LEFT JOIN ratio r ON r.account_locator = m.account_locator AND r.usage_date = DATE(m.start_time)) b
  WHERE start_time >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND start_time < DATEADD(day, -:settle_days, __AS_OF_DATE__)
    -- the CLOUD_SERVICES_ONLY row is cloud services with no warehouse behind it, not a warehouse
    AND COALESCE(warehouse_name, '') <> 'CLOUD_SERVICES_ONLY'
  GROUP BY account_locator, warehouse_id
),
rate AS (
  -- the account's own compute rate, so cost is in what the invoice actually charges
  SELECT account_locator, MAX(currency) AS currency,
         SUM(usage_in_currency) / NULLIF(SUM(usage), 0) AS compute_rate
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_type ILIKE 'compute'
    AND usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
s AS (
  SELECT w.*, rate.currency, rate.compute_rate,
         100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * credits / NULLIF(SUM(credits) OVER (), 0) AS share_of_org_pct,
         ROW_NUMBER() OVER (ORDER BY credits DESC) AS rank_in_org
  FROM w LEFT JOIN rate ON rate.account_locator = w.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       region, warehouse_name, warehouse_id, rank_in_org, credits, cloud_services_credits,
       prev_credits, change_pct, share_of_org_pct, active_days,
       currency, compute_rate, credits * compute_rate AS est_cost,
       credits * __CREDIT_PRICE__ AS est_cost_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN credits = 0 THEN 'no_credits_in_window' END AS not_assessed_reason,
       CASE
         WHEN credits = 0 THEN 'NOT_ASSESSED'
         WHEN credits < :min_credits THEN 'OK'
         WHEN change_pct >= :crit_growth_pct THEN 'CRITICAL'
         WHEN prev_credits = 0 OR change_pct >= :warn_growth_pct THEN 'WARN'
         WHEN share_of_org_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
WHERE rank_in_org <= :top_n
ORDER BY rank_in_org
