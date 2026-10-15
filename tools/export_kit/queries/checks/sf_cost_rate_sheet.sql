-- query_id: sf_cost_rate_sheet
-- title: Contract rates by usage type and rate changes
-- domain: cost   tier: standard
-- entity: rates = usage_type, service_type
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_change_pct (default 1) change pct: at or above this the row reads WARN;
--   :warn_price_gap_pct (default 5) price gap pct: at or above this the row reads WARN;
--   :crit_price_gap_pct (default 15) price gap pct: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one usage type x service type on this account's rate sheet. latest_rate is the
--   effective contract rate on the last day (per credit for compute and serverless types, per TB for
--   storage and transfer); first_rate is the rate at the window start. price_gap_pct compares a compute
--   consumption credit rate (rating type compute, billing type consumption; never storage, transfer or rebates)
--   with the credit price the audit's $ columns use.
-- healthy: status = OK when rates did not change in the window and the audit's credit price matches the
--   contract rate.
-- investigate_if: WARN when a rate moved by >= warn_change_pct in the window, or a credit rate is >=
--   warn_price_gap_pct away from the audit price; CRITICAL at >= crit_price_gap_pct.
-- actions: 1) rerun the export without --credit-price (it then reads the invoice rate) or with the
--   contract rate shown here (free); 2) tell finance about rate changes so forecasts use them (config);
--   3) use the rate sheet in renewal talks, e.g. services priced above compute (spend).
-- next: none
-- caveats: needs ORGANIZATION_USAGE access (ORGADMIN or a granted role); without it this check fails.
--   Rates are in the contract currency; a non-USD rate is not compared with the USD price.
WITH r AS (
  -- Rating type says what the rate is per (compute = credit; storage, data_transfer = TB); billing type
  -- separates consumption from rebates and support. The legacy usage_type text is only a fallback.
  SELECT "DATE" AS rate_date, usage_type, service_type, rating_type, billing_type, currency, effective_rate,
         COALESCE(LOWER(rating_type) IN ('storage', 'data_transfer'),
                  usage_type ILIKE '%storage%' OR usage_type ILIKE '%transfer%') AS non_credit
  FROM SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY
  WHERE account_locator = __ACCOUNT_ID__
    AND "DATE" >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND "DATE" < __AS_OF_DATE__
),
agg AS (
  SELECT usage_type, service_type, rating_type, billing_type, currency, BOOLOR_AGG(non_credit) AS non_credit,
         MIN(rate_date) AS first_date, MAX(rate_date) AS latest_date,
         MIN_BY(effective_rate, rate_date) AS first_rate,
         MAX_BY(effective_rate, rate_date) AS latest_rate,
         MIN(effective_rate) AS min_rate, MAX(effective_rate) AS max_rate,
         COUNT(DISTINCT effective_rate) AS distinct_rates
  FROM r
  GROUP BY usage_type, service_type, rating_type, billing_type, currency
),
s AS (
  SELECT agg.*,
         100 * (latest_rate - first_rate) / NULLIF(first_rate, 0) AS change_pct,
         100 * (max_rate - min_rate) / NULLIF(min_rate, 0) AS range_pct,
         IFF(non_credit OR currency <> 'USD' OR LOWER(COALESCE(rating_type, 'compute')) <> 'compute'
             OR LOWER(COALESCE(billing_type, 'consumption')) <> 'consumption', NULL,
             100 * (latest_rate - __CREDIT_PRICE__) / __CREDIT_PRICE__) AS price_gap_pct
  FROM agg
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_type, service_type,
       rating_type, billing_type, currency, first_date, latest_date, first_rate, latest_rate, min_rate, max_rate,
       distinct_rates, change_pct, __CREDIT_PRICE__ AS app_credit_price_usd, price_gap_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN latest_rate IS NULL THEN 'no_rate' END AS not_assessed_reason,
       CASE
         WHEN latest_rate IS NULL THEN 'NOT_ASSESSED'
         WHEN ABS(price_gap_pct) >= :crit_price_gap_pct THEN 'CRITICAL'
         WHEN ABS(price_gap_pct) >= :warn_price_gap_pct THEN 'WARN'
         WHEN range_pct >= :warn_change_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY status = 'OK', usage_type, service_type
