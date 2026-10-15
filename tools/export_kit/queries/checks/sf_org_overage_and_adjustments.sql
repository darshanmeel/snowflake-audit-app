-- query_id: sf_org_overage_and_adjustments
-- title: On-demand overage already billed, and billing adjustments that restate past days
-- domain: cost   tier: standard
-- money: overage_amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account (not available to reseller customers)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: last days left out while billing data is still
--   arriving; :recent_days (default 7) recent days: overage on every one of them reads CRITICAL;
--   :warn_amount (default 100) amount: overage or adjustments at or above this read WARN;
--   :crit_amount (default 1000) amount: overage at or above this reads CRITICAL
-- empty_if: org_account_only, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one contract x account x service type x currency. overage_amount is billed at the
--   on-demand rate after prepaid capacity ran out; capacity_amount is billed against prepaid capacity
--   (capacity plus rollover). overage_premium_pct = how much dearer a credit is on demand than on
--   capacity. adjustment_amount is what restated rows changed; open_month_adjustment_amount is the part
--   in the current month, which can still change. Amounts are in the invoice currency.
-- healthy: status = OK when nothing is billed at the on-demand rate and adjustments are small.
-- investigate_if: WARN when overage_amount or adjustments are >= warn_amount; CRITICAL when overage_amount
--   is >= crit_amount, or overage was billed on every one of the last recent_days days.
-- actions: 1) find which service type drives the overage and open its check in that account (free);
--   2) tune or suspend that feature, or watch the balance in sf_cost_contract_balance_burn (config);
--   3) buy more capacity or renegotiate before the next overage day, as on-demand costs more than
--   capacity (spend).
-- next: sf_cost_contract_balance_burn
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles; without
--   access the check is not assessed. Lags up to 72 hours, so the last settle_days are left out, and rows
--   can change until month end. Rebate rows are negative and shown in their own column, never netted into
--   consumption. Adjustment rows are also inside the amounts they restate, so adjustment_amount is never
--   added to overage or capacity. Overage, capacity and adjustments are never summed.
WITH u AS (
  SELECT contract_number, account_locator, MAX(account_name) AS account_name,
         COALESCE(service_type, '(none)') AS service_type, currency, usage_date,
         SUM(IFF(LOWER(balance_source) = 'overage', usage_in_currency, 0)) AS overage_amt,
         SUM(IFF(LOWER(balance_source) = 'overage', usage, 0)) AS overage_qty,
         SUM(IFF(LOWER(balance_source) IN ('capacity', 'rollover'), usage_in_currency, 0)) AS capacity_amt,
         SUM(IFF(LOWER(balance_source) IN ('capacity', 'rollover'), usage, 0)) AS capacity_qty,
         SUM(IFF(LOWER(balance_source) = 'rebate', usage_in_currency, 0)) AS rebate_amt,
         SUM(IFF(is_adjustment, usage_in_currency, 0)) AS adjustment_amt
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY contract_number, account_locator, COALESCE(service_type, '(none)'), currency, usage_date
),
a AS (
  SELECT contract_number, account_locator, MAX(account_name) AS account_name, service_type, currency,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), overage_amt, 0)) AS overage_amount,
         SUM(IFF(usage_date < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), overage_amt, 0)) AS prev_overage_amount,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), overage_qty, 0)) AS overage_qty,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), capacity_amt, 0)) AS capacity_amount,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), capacity_qty, 0)) AS capacity_qty,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), rebate_amt, 0)) AS rebate_amount,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), adjustment_amt, 0)) AS adjustment_amount,
         SUM(IFF(usage_date >= DATE_TRUNC('month', __AS_OF_DATE__), adjustment_amt, 0)) AS open_month_adjustment_amount,
         COUNT(DISTINCT IFF(overage_amt > 0
                            AND usage_date >= DATEADD(day, -(:recent_days + :settle_days), __AS_OF_DATE__),
                            usage_date, NULL)) AS overage_days_recent
  FROM u
  GROUP BY contract_number, account_locator, service_type, currency
),
s AS (
  SELECT a.*, overage_amount / NULLIF(overage_qty, 0) AS overage_rate,
         capacity_amount / NULLIF(capacity_qty, 0) AS capacity_rate,
         100 * (overage_amount / NULLIF(overage_qty, 0) / NULLIF(capacity_amount / NULLIF(capacity_qty, 0), 0) - 1)
           AS overage_premium_pct
  FROM a
)
SELECT :period_days AS window_days, account_locator AS account_id, contract_number, account_name,
       account_locator, service_type, currency, overage_amount, prev_overage_amount, overage_qty,
       overage_rate, capacity_amount, capacity_rate, overage_premium_pct, rebate_amount,
       adjustment_amount, open_month_adjustment_amount, overage_days_recent,
       IFF(open_month_adjustment_amount <> 0, 'can still change', NULL) AS adjustment_note,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN overage_amount >= :crit_amount THEN 'CRITICAL'
         WHEN overage_amount >= :warn_amount AND overage_days_recent >= :recent_days THEN 'CRITICAL'
         WHEN overage_amount >= :warn_amount OR ABS(adjustment_amount) >= :warn_amount THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY overage_amount DESC, ABS(adjustment_amount) DESC
