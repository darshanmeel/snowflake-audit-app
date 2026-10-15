-- query_id: sf_cost_invoice_vs_metered
-- title: Invoice amounts vs metered credits at the app price
-- domain: cost   tier: standard
-- money: invoice_amount
-- entity: usage types = usage_type
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY,
--   SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :warn_gap_pct (default 5) gap
--   pct: at or above this the row reads WARN; :crit_gap_pct (default 15) gap pct: at or above this the
--   row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one invoice usage type for this account, plus an 'ALL CREDITS' row.
--   invoice_amount is what Snowflake bills in the contract currency; effective_rate = amount / usage
--   (per credit, or per TB for storage and transfer). For credit types, rate_gap_pct compares it with
--   the credit price every $ column in this audit uses. The 'ALL CREDITS' row also compares invoiced
--   credits with METERING_DAILY_HISTORY credits_billed (credit_gap_pct).
-- healthy: status = OK when the invoice rate and credits match what the audit uses within warn_gap_pct,
--   so its dollars can be quoted to finance.
-- investigate_if: WARN when a gap is >= warn_gap_pct; CRITICAL when >= crit_gap_pct.
-- actions: 1) rerun the export without --credit-price so it reads the invoice rate, or pass the
--   contract rate (free); 2) if credits differ, check for other accounts, reader accounts or
--   adjustments on the invoice (config); 3) raise a discrepancy with your Snowflake account team
--   (spend).
-- next: none
-- caveats: needs ORGANIZATION_USAGE access (ORGADMIN or a granted role); without it this check fails.
--   The org views lag up to a day or more, so the last settle_days are left out on both sides. Non-USD
--   contracts cannot be compared with a USD price and are NOT_ASSESSED.
WITH inv AS (
  -- Rating type says what the quantity is (compute = credits, storage / data_transfer = TB); billing type
  -- separates consumption from rebates and support. The legacy usage_type text is only a fallback.
  SELECT usage_type, rating_type, billing_type,
         COALESCE(LOWER(rating_type) IN ('storage', 'data_transfer'),
                  usage_type ILIKE '%storage%' OR usage_type ILIKE '%transfer%') AS non_credit,
         MAX(currency) AS currency, COUNT(DISTINCT currency) AS currencies,
         SUM(usage) AS usage_qty, SUM(usage_in_currency) AS amount
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE account_locator = __ACCOUNT_ID__
    AND usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY usage_type, rating_type, billing_type
),
met AS (
  SELECT SUM(credits_billed) AS metered_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
),
rows_ AS (
  SELECT usage_type, rating_type, billing_type, non_credit, currency, currencies, usage_qty, amount,
         CAST(NULL AS DOUBLE) AS metered_credits
  FROM inv
  UNION ALL
  -- only credit-rated consumption is comparable with metered credits (rebates and support are not)
  SELECT 'ALL CREDITS', 'compute', 'consumption', FALSE, MAX(inv.currency), COUNT(DISTINCT inv.currency),
         SUM(inv.usage_qty), SUM(inv.amount), MAX(met.metered_credits)
  FROM inv CROSS JOIN met
  WHERE NOT inv.non_credit AND LOWER(COALESCE(inv.rating_type, 'compute')) = 'compute'
    AND LOWER(COALESCE(inv.billing_type, 'consumption')) = 'consumption'
),
s AS (
  SELECT r.*, amount / NULLIF(usage_qty, 0) AS effective_rate,
         IFF(non_credit OR LOWER(COALESCE(billing_type, 'consumption')) <> 'consumption', NULL,
             100 * (amount / NULLIF(usage_qty, 0) - __CREDIT_PRICE__) / __CREDIT_PRICE__) AS rate_gap_pct,
         100 * (usage_qty - metered_credits) / NULLIF(metered_credits, 0) AS credit_gap_pct
  FROM rows_ r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_type, rating_type, billing_type,
       usage_type = 'ALL CREDITS' AS is_total_row, currency,
       usage_qty AS invoice_usage, amount AS invoice_amount, effective_rate,
       __CREDIT_PRICE__ AS app_credit_price_usd, rate_gap_pct,
       metered_credits, credit_gap_pct,
       metered_credits * __CREDIT_PRICE__ AS est_metered_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN usage_qty IS NULL THEN 'no_invoice_rows'
            WHEN non_credit THEN 'not_credit_based'
            WHEN LOWER(COALESCE(billing_type, 'consumption')) <> 'consumption' THEN 'not_consumption'
            WHEN currencies > 1 OR currency <> 'USD' THEN 'currency_not_usd'
            WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN usage_qty IS NULL OR non_credit OR LOWER(COALESCE(billing_type, 'consumption')) <> 'consumption' OR currencies > 1 OR currency <> 'USD' OR __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN ABS(rate_gap_pct) >= :crit_gap_pct OR ABS(credit_gap_pct) >= :crit_gap_pct THEN 'CRITICAL'
         WHEN ABS(rate_gap_pct) >= :warn_gap_pct OR ABS(credit_gap_pct) >= :warn_gap_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY usage_type = 'ALL CREDITS' DESC, invoice_amount DESC NULLS LAST
