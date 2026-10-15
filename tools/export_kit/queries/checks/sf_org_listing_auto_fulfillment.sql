-- query_id: sf_org_listing_auto_fulfillment
-- title: Listing auto-fulfillment cost by account and service type
-- domain: cost   tier: standard
-- money: est_cost
-- entity: provider accounts = provider_account_locator, service_type
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.LISTING_AUTO_FULFILLMENT_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :warn_amount (default 100)
--   amount: at or above this the row reads WARN; :crit_amount (default 1000) amount: at or above this
--   the row reads CRITICAL; :warn_growth_pct (default 50) growth pct: at or above this the row reads WARN
-- empty_if: org_account_only, view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The docs call the amounts estimates that may not match
--   USAGE_IN_CURRENCY_DAILY.
-- read_this: one row = one provider account and service type (DATA_TRANSFER, REPLICATION or STORAGE) of listing
--   auto-fulfillment. account_name and account_locator are the secure share area where the usage happened, not the
--   provider; the provider columns are empty when the usage cannot be attributed, and the row then falls back to the
--   share area. est_cost is the view's estimate in the contract currency; est_usage is the same in the
--   service's own unit (credits or bytes), so rows of different service types are never added together.
-- healthy: status = OK when a row costs less than warn_amount or is flat.
-- investigate_if: WARN when it costs >= warn_amount and grew >= warn_growth_pct or is new; CRITICAL when it costs
--   >= crit_amount.
-- actions: 1) check that the listings behind the spend still have buyers in the remote regions (free);
--   2) remove unused regions from the listing or lengthen the refresh schedule (config); 3) stop fulfilling
--   a listing that costs more than it earns (spend)
-- next: sf_cost_listing_auto_fulfillment
-- caveats: readable only from the organization account or with the organization billing roles; without them this
--   check fails. The values are estimates and lag up to 24 hours. They can change until month end. Amounts are in
--   the contract currency, not list USD, and are never added to credits or to other service types.
WITH r AS (
  SELECT COALESCE(provider_account_locator, account_locator) AS provider_account_locator,
         MAX(account_name) AS account_name, MAX(account_locator) AS account_locator, MAX(region) AS region,
         service_type, currency, MAX(provider_account_name) AS provider_account_name,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), estimated_usage, 0)) AS est_usage,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), estimated_usage_in_currency, 0)) AS est_cost,
         SUM(IFF(usage_date < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), estimated_usage_in_currency, 0)) AS prev_est_cost
  FROM SNOWFLAKE.ORGANIZATION_USAGE.LISTING_AUTO_FULFILLMENT_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY COALESCE(provider_account_locator, account_locator), service_type, currency
)
SELECT :period_days AS window_days, provider_account_locator AS account_id, provider_account_locator,
       account_name, account_locator, region,
       provider_account_name, service_type, currency, est_usage, est_cost, prev_est_cost,
       100 * (est_cost - prev_est_cost) / NULLIF(prev_est_cost, 0) AS change_pct,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN est_cost >= :crit_amount THEN 'CRITICAL'
         WHEN est_cost >= :warn_amount AND (prev_est_cost = 0
              OR 100 * (est_cost - prev_est_cost) / NULLIF(prev_est_cost, 0) >= :warn_growth_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM r
ORDER BY est_cost DESC
