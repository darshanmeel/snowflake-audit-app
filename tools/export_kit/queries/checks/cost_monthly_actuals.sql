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
WITH -- Shared by every Snowflake money check, so their totals always agree.
-- One row per day x service type (credits billed, after the cloud-services adjustment) plus one
-- row per day of storage (TB-days). period: current | previous | older, relative to the window.
cost_lines AS (
  SELECT usage_date, sku_name, billing_origin_product, usage_type, usage_unit, qty, rate,
         qty * rate AS usd,
         CASE WHEN usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) THEN 'current'
              WHEN usage_date >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) THEN 'previous'
              ELSE 'older' END AS period
  FROM (
    SELECT usage_date, service_type AS sku_name, service_type AS billing_origin_product,
           'COMPUTE_TIME' AS usage_type, 'CREDITS' AS usage_unit,
           credits_billed AS qty,
           -- AI credits (Cortex, Copilot) have their own price
           IFF(REGEXP_LIKE(service_type, '(^|.*_)(AI|CORTEX|COCO|COWORK)(_.*|$)'),
               __AI_CREDIT_PRICE__, __CREDIT_PRICE__) AS rate
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
    WHERE usage_date >= DATEADD(day, -400, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
    UNION ALL
    SELECT usage_date, 'STORAGE', 'STORAGE', 'STORAGE_SPACE', 'TB_DAYS',
           (COALESCE(storage_bytes, 0) + COALESCE(stage_bytes, 0) + COALESCE(failsafe_bytes, 0)
            + COALESCE(hybrid_table_storage_bytes, 0)) / POWER(1024, 4),
           __STORAGE_PRICE_TB_MONTH__ / 30.4
    FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
    WHERE usage_date >= DATEADD(day, -400, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
    UNION ALL
    -- Archive tiers have their own rate that the app does not know: NULL rate = unpriced, never $0.
    SELECT usage_date, 'STORAGE_ARCHIVE', 'STORAGE_ARCHIVE', 'STORAGE_SPACE', 'TB_DAYS',
           (COALESCE(archive_storage_cool_bytes, 0) + COALESCE(archive_storage_cold_bytes, 0)) / POWER(1024, 4),
           CAST(NULL AS DOUBLE)
    FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
    WHERE usage_date >= DATEADD(day, -400, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
      AND COALESCE(archive_storage_cool_bytes, 0) + COALESCE(archive_storage_cold_bytes, 0) > 0
    UNION ALL
    -- Estimated like sf_cost_data_transfer_egress (same per-TB rates). The view lists only transfer out of
    -- the region (same-region transfer is free and has no row): another region of the same cloud, or another cloud.
    SELECT CAST(start_time AS DATE), 'DATA_TRANSFER', 'DATA_TRANSFER', 'DATA_TRANSFER', 'TB',
           SUM(TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred))) / POWER(1024, 4),
           IFF(COALESCE(UPPER(target_cloud) = UPPER(source_cloud), FALSE), 20, 90)
    FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
    WHERE start_time >= DATEADD(day, -400, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    GROUP BY CAST(start_time AS DATE), COALESCE(UPPER(target_cloud) = UPPER(source_cloud), FALSE)
  ) x
),
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
