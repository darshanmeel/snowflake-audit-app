-- query_id: sf_org_cloud_services_billed_by_account
-- title: Cloud services billed above the 10% allowance, per account across the organization
-- domain: cost   tier: standard
-- money: est_billed_cs_amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY,
--   SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_USAGE_VIEWER and
--   ORGANIZATION_BILLING_VIEWER in the organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: last days left out while billing data is still arriving;
--   :warn_amount (default 100) amount: billed cloud services at or above this read WARN;
--   :crit_amount (default 1000) amount: at or above this the row reads CRITICAL;
--   :warn_ratio_pct (default 10) ratio pct: cloud services above this share of compute read WARN
-- empty_if: org_account_only, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account. Each day, cloud services are free up to 10% of that day's virtual
--   warehouse compute credits; billed_cs_credits is the part above it, summed over the window's days (days
--   with no usage count as zero). compute_credits is warehouse compute only; cloud_services_ratio_pct =
--   cloud services used over that compute. est_billed_cs_amount = billed credits x the account's average billed rate per credit, in the
--   invoice currency.
-- healthy: status = OK when an account's cloud services stay within the 10% allowance, or cost little.
-- investigate_if: WARN when billed cloud services cost >= warn_amount, or the ratio is >= warn_ratio_pct
--   with any credits billed; CRITICAL when they cost >= crit_amount.
-- actions: 1) run sf_cost_cloud_services_drivers in that account to see which warehouse, user and query
--   type drive it (free); 2) cut metadata-heavy work: frequent SHOW/DESCRIBE, tiny single-row INSERTs,
--   COPY over huge file lists (config); 3) batch small statements into fewer, larger ones (spend).
-- next: sf_cost_cloud_services_drivers
-- not_assessed_reasons: unpriced: no billed rate per credit is available for the account, so the credits
--   cannot be priced
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE viewer database roles; without access
--   the check is not assessed. Lags up to 72 hours, so the last settle_days are left out. The allowance
--   is worked out per account per day, so the service rows are added up before judging; serverless and
--   AI credits are not part of the compute base (ratio denominator = WAREHOUSE_METERING compute). Only billed cloud services are priced, never the gross figure. Dates are UTC. The amount is
--   in the invoice currency, not list USD.
WITH days AS (
  SELECT DATEADD(day, -(seq4() + 1) - :settle_days, __AS_OF_DATE__) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
),
m AS (
  SELECT account_locator, MAX(account_name) AS account_name, usage_date,
         -- the 10% allowance is read against virtual warehouse compute only, not serverless
         SUM(IFF(service_type = 'WAREHOUSE_METERING', credits_used_compute, 0)) AS compute_credits,
         SUM(credits_used_cloud_services) AS cs_used,
         SUM(credits_adjustment_cloud_services) AS cs_adjustment
  FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator, usage_date
),
accts AS (
  SELECT account_locator, MAX(account_name) AS account_name FROM m GROUP BY account_locator
),
spine AS (
  SELECT a.account_locator, a.account_name, s.d,
         COALESCE(m.compute_credits, 0) AS compute_credits,
         COALESCE(m.cs_used, 0) AS cs_used,
         COALESCE(m.cs_adjustment, 0) AS cs_adjustment
  FROM accts a
  CROSS JOIN (SELECT d FROM days WHERE d >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)) s
  LEFT JOIN m ON m.account_locator = a.account_locator AND m.usage_date = s.d
),
agg AS (
  SELECT account_locator, MAX(account_name) AS account_name,
         SUM(compute_credits) AS compute_credits, SUM(cs_used) AS cs_used_credits,
         SUM(GREATEST(cs_used + cs_adjustment, 0)) AS billed_cs_credits,
         COUNT_IF(cs_used + cs_adjustment > 0) AS billed_days
  FROM spine
  GROUP BY account_locator
),
rate AS (
  SELECT account_locator, MAX(currency) AS currency,
         -- Cloud services rate, else the compute rate; never a blend with serverless or AI service types.
         COALESCE(SUM(IFF(service_type = 'CLOUD_SERVICES', usage_in_currency, 0))
                    / NULLIF(SUM(IFF(service_type = 'CLOUD_SERVICES', usage, 0)), 0),
                  SUM(IFF(service_type = 'WAREHOUSE_METERING', usage_in_currency, 0))
                    / NULLIF(SUM(IFF(service_type = 'WAREHOUSE_METERING', usage, 0)), 0)) AS credit_rate
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE service_type IN ('CLOUD_SERVICES', 'WAREHOUSE_METERING')
    AND usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
s AS (
  SELECT agg.*, rate.currency, rate.credit_rate,
         100 * cs_used_credits / NULLIF(compute_credits, 0) AS ratio_pct,
         billed_cs_credits * rate.credit_rate AS billed_amount
  FROM agg LEFT JOIN rate ON rate.account_locator = agg.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       compute_credits, cs_used_credits AS cloud_services_credits, billed_cs_credits, billed_days,
       ratio_pct AS cloud_services_ratio_pct, currency, credit_rate,
       billed_amount AS est_billed_cs_amount,
       CASE WHEN billed_cs_credits > 0 AND billed_amount IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN billed_cs_credits > 0 AND billed_amount IS NULL THEN 'NOT_ASSESSED'
         WHEN billed_amount >= :crit_amount THEN 'CRITICAL'
         WHEN billed_amount >= :warn_amount THEN 'WARN'
         WHEN billed_cs_credits > 0 AND ratio_pct >= :warn_ratio_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY billed_amount DESC NULLS LAST, billed_cs_credits DESC
