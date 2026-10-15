-- query_id: cost_monthly_actuals
-- title: Dollars per calendar month, by account and service
-- domain: cost   tier: standard
-- entity: service-months = billing_origin_product, month_start
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account and service type's total list-priced spend for one calendar
--   month. month_start is the first day of that month; is_partial_month is TRUE for the current,
--   still-in-progress calendar month AND for the export's own oldest month if the snapshot's
--   history starts partway through it - read either kind's total as partial, never as the month's
--   final number (never scaled up to a full month; sf_cost_month_end_forecast is the only
--   forecast). partial_reason says which kind ('month_in_progress' or 'history_starts_mid_month').
--   days_captured is how many distinct days that month have a usage row for any service on this
--   account, a quick honesty check on how complete the month's total is; first_day/last_day are
--   that range's own earliest/latest usage_date, so a partial month can be labelled honestly (e.g.
--   "16-22 Sep") instead of implied as the whole month. All three and partial_reason are the same
--   on every service row of a month, since a service that skips days does not make the month partial.
-- healthy: n/a - inventory (actuals, not a verdict)
-- investigate_if: n/a - inventory (actuals, not a verdict); pair with cost_period_over_period for a
--   judged comparison
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: last 13 calendar months by service type; the current month is marked
--   partial.
WITH __INCLUDE_cost_lines__,
-- Judged over the whole month across all services, so sparse services don't mark a full month partial.
months AS (
  SELECT DATE_TRUNC('month', usage_date) AS month_start,
         COUNT(DISTINCT usage_date) AS days_captured,
         MIN(usage_date) AS first_day, MAX(usage_date) AS last_day
  FROM cost_lines
  WHERE usage_date >= DATEADD(month, -12, DATE_TRUNC('month', __AS_OF_DATE__))
  GROUP BY DATE_TRUNC('month', usage_date)
),
by_service AS (
  SELECT billing_origin_product, DATE_TRUNC('month', usage_date) AS month_start,
         SUM(usd) AS net_list_cost_usd,
         IFF(COUNT_IF(rate IS NULL) > 0, 'unpriced', 'priced') AS price_basis
  FROM cost_lines
  WHERE usage_date >= DATEADD(month, -12, DATE_TRUNC('month', __AS_OF_DATE__))
  GROUP BY billing_origin_product, DATE_TRUNC('month', usage_date)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, s.billing_origin_product,
       s.month_start, 'USD' AS currency_code, s.net_list_cost_usd,
       m.days_captured,
       s.month_start = DATE_TRUNC('month', __AS_OF_DATE__)
         OR m.days_captured < DAY(LAST_DAY(s.month_start)) AS is_partial_month,
       CASE WHEN s.month_start = DATE_TRUNC('month', __AS_OF_DATE__) THEN 'month_in_progress'
            WHEN m.days_captured < DAY(LAST_DAY(s.month_start)) THEN 'history_starts_mid_month'
       END AS partial_reason,
       s.price_basis, m.first_day, m.last_day
FROM by_service s
LEFT JOIN months m ON m.month_start = s.month_start
ORDER BY s.month_start DESC, s.billing_origin_product
