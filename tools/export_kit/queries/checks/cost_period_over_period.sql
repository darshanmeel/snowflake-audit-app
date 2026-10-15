-- query_id: cost_period_over_period
-- title: Spend this period versus the equal-length period before it, by account and service
-- domain: cost   tier: standard
-- entity: services = billing_origin_product
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_increase_pct (default 25) percent increase in list-priced spend, current period over
--   previous, at/above which WARN; :crit_increase_pct (default 50) percent increase at/above which
--   CRITICAL; :min_spend_usd (default 50) the current period's own list-priced spend must be at least
--   this before a percent change is judged - below it the row reads OK regardless of the swing, since a
--   percent figure on a tiny base is noise
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account and service type's spend in the selected window against the
--   equal-length window immediately before it, both priced at the effective list price.
--   est_current_usd_list and est_previous_usd_list are the two totals; est_change_usd_list and
--   change_pct compare them. price_basis (free/priced/unpriced) discloses pricing coverage across
--   both windows combined; not_assessed_reason explains a NOT_ASSESSED row.
-- healthy: status OK - no increase at/above :warn_increase_pct, or the row's own current-period spend
--   (a real $0 counts) sits below :min_spend_usd
-- investigate_if: CRITICAL - the increase is at/above :crit_increase_pct on at least :min_spend_usd
--   of current spend, or the row is brand-new spend above the floor with nothing in the previous
--   period to compare against (there is no honest percentage for a jump from zero, so it reads
--   CRITICAL outright); WARN - at/above :warn_increase_pct. NOT_ASSESSED - read
--   not_assessed_reason: 'previous_window_not_covered' when the whole account's own earliest
--   recorded usage (across every service, not just this row) does not reach back far enough to
--   cover the previous window, so no comparison anywhere can be trusted at this window length;
--   'current_period_unpriced' when this row's current-period spend could not be priced at all (no
--   credit price is available for the window), so there is no dollar figure to judge;
--   'previous_period_unpriced' is the same gap on the previous period's own side.
-- actions: 1) open cost_dollarized_by_service_day for this account and window, sorted by day and
--   service, to see which service actually moved (free); 2) check cost_monthly_actuals for the same
--   account and service to see whether this is a genuine trend or one busy stretch inside an
--   otherwise flat month (free); 3) if the increase is real usage rather than a one-off backfill or
--   restatement, the matching tab (Warehouses, Serverless features, Tasks & pipelines) names the
--   resource driving it, and right-sizing or scaling it down is the fix (config, or spend if the
--   extra usage is deliberate growth).
-- next: none
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced; previous_window_not_covered: the account's earliest usage does not reach back over the whole
--   previous window, so there is nothing honest to compare with
-- caveats: Snowflake version: product = Snowflake service type; a side with no price is NOT_ASSESSED,
--   never judged.
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
by_product AS (
  SELECT billing_origin_product,
         SUM(IFF(period = 'current', usd, 0)) AS cur_usd,
         SUM(IFF(period = 'previous', usd, 0)) AS prev_usd,
         COUNT_IF(rate IS NULL AND period IN ('current', 'previous')) AS unpriced_rows
  FROM cost_lines
  WHERE period IN ('current', 'previous')
  GROUP BY billing_origin_product
),
-- Earliest day with any usage across every service: a young account has no honest previous window.
coverage AS (
  SELECT MIN(usage_date) AS first_usage_date FROM cost_lines WHERE qty > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, billing_origin_product,
       IFF(unpriced_rows > 0, NULL, cur_usd) AS est_current_usd_list,
       IFF(unpriced_rows > 0, NULL, prev_usd) AS est_previous_usd_list,
       IFF(unpriced_rows > 0, NULL, cur_usd - prev_usd) AS est_change_usd_list,
       IFF(unpriced_rows > 0 OR prev_usd = 0, NULL, 100 * (cur_usd - prev_usd) / prev_usd) AS change_pct,
       IFF(unpriced_rows > 0, 'unpriced', 'priced') AS price_basis,
       CASE
         WHEN first_usage_date IS NULL OR first_usage_date > DATEADD(day, -2 * :period_days, __AS_OF_DATE__)
           THEN 'NOT_ASSESSED'
         WHEN unpriced_rows > 0 THEN 'NOT_ASSESSED'
         WHEN GREATEST(cur_usd, prev_usd) < :min_spend_usd THEN 'OK'
         WHEN prev_usd = 0 THEN 'WARN'
         WHEN 100 * (cur_usd - prev_usd) / prev_usd >= :crit_increase_pct THEN 'CRITICAL'
         WHEN 100 * (cur_usd - prev_usd) / prev_usd >= :warn_increase_pct THEN 'WARN'
         ELSE 'OK'
       END AS status,
       CASE WHEN first_usage_date IS NULL OR first_usage_date > DATEADD(day, -2 * :period_days, __AS_OF_DATE__)
              THEN 'previous_window_not_covered'
            WHEN unpriced_rows > 0 THEN 'unpriced' END AS not_assessed_reason
FROM by_product CROSS JOIN coverage
ORDER BY est_change_usd_list DESC NULLS LAST
