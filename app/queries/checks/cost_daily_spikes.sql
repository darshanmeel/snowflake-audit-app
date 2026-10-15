-- query_id: cost_daily_spikes
-- title: Days an account or service's spend jumped well above its own recent trailing baseline
-- domain: cost   tier: standard
-- entity: service-days = billing_origin_product, usage_date
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :baseline_days (default 14) trailing days, immediately before each scanned day, whose median
--   spend is that day's baseline; :spike_ratio (default 2.0) a day flags once its own spend is at least
--   this many times its trailing baseline median; :min_spend_usd (default 50) a day's own spend must be
--   at least this before it can flag, so a jump between two tiny dollar figures never reads as a spike;
--   :min_baseline_days (default 7) days with spend the baseline window must hold before a day is judged
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one day this account and service's own spend cleared :spike_ratio times its
--   own trailing :baseline_days median, at or above the :min_spend_usd floor. est_day_usd_list is
--   that day's total; est_baseline_usd_list is the trailing median it is judged against;
--   spike_ratio_actual is est_day_usd_list over that median; top_skus names the service types that
--   made up most of the day (the drivers to look at first).
-- healthy: status = OK is never itself returned as a row (see caveats: this query emits ONLY WARN
--   or NOT_ASSESSED days) - a day whose own spend never clears :min_spend_usd, or that clears the
--   floor but not :spike_ratio, or that clears both but has no baseline, simply has no row when the
--   floor alone is what stops it, so "no row for an account and service in the window" is (mostly)
--   the healthy case - see NOT_ASSESSED below for the one exception.
-- investigate_if: WARN - every row returned above the floor with a real trailing baseline: a real
--   jump on a real amount of money. NOT_ASSESSED - read not_assessed_reason: this account and
--   service cleared :min_spend_usd on this day but has no earlier spend at all in the trailing
--   :baseline_days before it, so there is no baseline to judge it against (a brand-new account or a
--   service that only just started billing) - the $ floor is checked first, so a NOT_ASSESSED row
--   always represents a day with real money behind it, never a $1 non-event.
-- actions: 1) open cost_dollarized_by_service_day for this account and day and read top_skus
--   against it - a one-off correction usually shows as one service type, a genuine spike as several
--   (free); 2) check cost_period_over_period for the same account and service - one spike day
--   inside an otherwise flat period reads differently from a period that is trending up throughout
--   (free); 3) if the spike is real new usage (a task or load that started running more often, a
--   new warehouse, a bigger backfill) rather than a one-off correction, the matching domain tab
--   names the warehouse, task or pipe and whether it is worth scaling down (config) or is
--   deliberate growth (spend).
-- next: none
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced; baseline_too_short: fewer than :min_baseline_days days with spend before this day, so there is no
--   baseline to compare with
-- caveats: Snowflake version: baseline = median of the :baseline_days calendar days before, missing
--   days count as $0.
WITH __INCLUDE_cost_lines__,
days AS (
  SELECT DATEADD(day, -seq4() - 1, __AS_OF_DATE__) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
),
products AS (SELECT DISTINCT billing_origin_product FROM cost_lines),
daily AS (
  SELECT p.billing_origin_product, dd.d AS usage_date,
         COALESCE(SUM(c.usd), 0) AS usd,
         COUNT_IF(c.rate IS NULL) AS unpriced_rows,
         LISTAGG(DISTINCT c.sku_name, ', ') AS skus
  FROM products p
  CROSS JOIN days dd
  LEFT JOIN cost_lines c
    ON c.billing_origin_product = p.billing_origin_product AND c.usage_date = dd.d
  WHERE dd.d >= DATEADD(day, -(:period_days + :baseline_days), __AS_OF_DATE__)
  GROUP BY p.billing_origin_product, dd.d
),
scored AS (
  SELECT a.billing_origin_product, a.usage_date, a.usd, a.skus, a.unpriced_rows,
         MEDIAN(b.usd) AS baseline_usd,
         COUNT(b.usage_date) AS baseline_days_seen,
         COUNT_IF(b.usd > 0) AS baseline_active_days
  FROM daily a
  JOIN daily b
    ON b.billing_origin_product = a.billing_origin_product
   AND b.usage_date >= DATEADD(day, -:baseline_days, a.usage_date)
   AND b.usage_date < a.usage_date
  WHERE a.usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__)
  GROUP BY a.billing_origin_product, a.usage_date, a.usd, a.skus, a.unpriced_rows
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, billing_origin_product, usage_date,
       usd AS est_day_usd_list, baseline_usd AS est_baseline_usd_list, baseline_days_seen, baseline_active_days,
       IFF(baseline_usd > 0, usd / baseline_usd, NULL) AS spike_ratio_actual,
       skus AS top_skus,
       IFF(unpriced_rows > 0, 'unpriced', 'priced') AS price_basis,
       CASE
         WHEN unpriced_rows > 0 THEN 'NOT_ASSESSED'
         WHEN usd < :min_spend_usd THEN 'OK'
         WHEN baseline_active_days < :min_baseline_days THEN 'NOT_ASSESSED'
         WHEN baseline_usd > 0 AND usd / baseline_usd >= :spike_ratio THEN 'WARN'
         ELSE 'OK'
       END AS status,
       CASE WHEN unpriced_rows > 0 THEN 'unpriced'
            WHEN usd >= :min_spend_usd AND baseline_active_days < :min_baseline_days THEN 'baseline_too_short' END AS not_assessed_reason
FROM scored
WHERE usd > 0
ORDER BY usage_date DESC, billing_origin_product
