-- query_id: cost_chargeback_by_service
-- title: Chargeback by service type, with change vs the previous period
-- domain: cost   tier: standard
-- money: usd_list
-- entity: services = billing_origin_product
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_increase_pct (default 25) percent increase in list-priced spend, current period over
--   previous, at/above which WARN; :crit_increase_pct (default 50) percent increase at/above which
--   CRITICAL; :min_spend_usd (default 20) the current period's own list-priced spend must be at least
--   this before a percent change is judged - below it the row reads OK regardless of the swing. Needs
--   2x :period_days of billing history in the account for the previous-period comparison
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one service type's spend in the selected window against the equal-length
--   window right before it, both at the effective list price. A NULL service type is a genuine
--   unattributed-usage row, kept as its own line (service_label 'Unattributed'), never dropped.
--   usage_quantity is the native volume in usage_unit (credits, or TB-days for storage). usd_list
--   and prev_usd_list are the two totals; change_usd_list and change_pct compare them. price_basis
--   discloses pricing coverage across both windows combined; not_assessed_reason explains a
--   NOT_ASSESSED row.
-- healthy: status OK - no increase at/above :warn_increase_pct, or the row's own current-period spend
--   (a real $0 counts) sits below :min_spend_usd.
-- investigate_if: CRITICAL - the increase is at/above :crit_increase_pct on at least :min_spend_usd of
--   current spend, or brand-new spend above the floor with nothing in the previous period to compare
--   against. WARN - at/above :warn_increase_pct. NOT_ASSESSED - read not_assessed_reason:
--   'previous_window_not_covered' when the account's own earliest recorded usage does not reach back
--   far enough to cover the previous window at this window length; 'current_period_unpriced' /
--   'previous_period_unpriced' when that side's whole spend could not be priced at all.
-- actions: 1) look at usage_quantity next to the dollar move to see whether volume or price moved
--   (free); 2) open cost_monthly_actuals to see this service's 12-month trend (free); 3) if the
--   increase is deliberate growth, set or tighten a budget policy for that service before it
--   compounds another period (config, or spend if intentional).
-- next: none
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced; previous_window_not_covered: the account's earliest usage does not reach back over the whole
--   previous window, so there is nothing honest to compare with
-- caveats: Snowflake version: service = Snowflake service type (WAREHOUSE_METERING, SERVERLESS_TASK,
--   PIPE, ...).
WITH __INCLUDE_cost_lines__,
s AS (
  SELECT billing_origin_product, MAX(usage_unit) AS usage_unit,
         SUM(IFF(period = 'current', qty, 0)) AS qty,
         SUM(IFF(period = 'current', usd, 0)) AS usd,
         SUM(IFF(period = 'previous', usd, 0)) AS prev_usd,
         COUNT_IF(rate IS NULL AND period IN ('current', 'previous')) AS unpriced_rows
  FROM cost_lines
  WHERE period IN ('current', 'previous')
  GROUP BY billing_origin_product
),
total AS (SELECT SUM(IFF(unpriced_rows > 0, NULL, usd)) AS usd FROM s),
-- earliest usage across every service: a young account has no honest previous window
cov AS (SELECT MIN(usage_date) AS first_usage_date FROM cost_lines WHERE qty > 0)
SELECT :period_days AS window_days, s.billing_origin_product,
       INITCAP(REPLACE(s.billing_origin_product, '_', ' ')) AS service_label,
       s.usage_unit, s.qty AS usage_quantity,
       -- an unpriced service reads NULL ("-"), never $0
       IFF(s.unpriced_rows > 0, NULL, s.usd) AS usd_list,
       IFF(s.unpriced_rows > 0, NULL, 100 * s.usd / NULLIF(t.usd, 0)) AS share_of_total_pct,
       IFF(s.unpriced_rows > 0, NULL, s.prev_usd) AS prev_usd_list,
       IFF(s.unpriced_rows > 0, NULL, s.usd - s.prev_usd) AS change_usd_list,
       IFF(s.unpriced_rows > 0 OR s.prev_usd = 0, NULL, 100 * (s.usd - s.prev_usd) / s.prev_usd) AS change_pct,
       IFF(s.unpriced_rows > 0, 'unpriced', 'priced') AS price_basis,
       CASE
         WHEN first_usage_date IS NULL OR first_usage_date > DATEADD(day, -2 * :period_days, __AS_OF_DATE__) THEN 'NOT_ASSESSED'
         WHEN s.unpriced_rows > 0 THEN 'NOT_ASSESSED'
         WHEN GREATEST(s.usd, s.prev_usd) < :min_spend_usd THEN 'OK'
         WHEN s.prev_usd = 0 THEN 'WARN'
         WHEN 100 * (s.usd - s.prev_usd) / s.prev_usd >= :crit_increase_pct THEN 'CRITICAL'
         WHEN 100 * (s.usd - s.prev_usd) / s.prev_usd >= :warn_increase_pct THEN 'WARN'
         ELSE 'OK'
       END AS status,
       CASE WHEN first_usage_date IS NULL OR first_usage_date > DATEADD(day, -2 * :period_days, __AS_OF_DATE__) THEN 'previous_window_not_covered'
            WHEN s.unpriced_rows > 0 THEN 'unpriced' END AS not_assessed_reason
FROM s CROSS JOIN total t CROSS JOIN cov
ORDER BY s.usd DESC NULLS LAST
