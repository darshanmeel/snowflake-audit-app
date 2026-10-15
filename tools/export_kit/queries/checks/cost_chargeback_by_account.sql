-- query_id: cost_chargeback_by_account
-- title: Chargeback by account, with change vs the previous period
-- domain: cost   tier: standard
-- money: usd_list
-- entity: accounts = account_id
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
-- read_this: One row = one account's spend in the selected window against the equal-length window
--   right before it, both at the effective list price. Usage that belongs to no single account is
--   kept as its own line, never dropped. usd_list and prev_usd_list are the two totals;
--   change_usd_list and change_pct compare them, on the priced services; unpriced_services names any
--   service with no price (archive tiers), left out of both totals. not_assessed_reason explains a
--   NOT_ASSESSED row. The account name shown is
--   the account this export ran on.
-- healthy: status OK - no increase at/above :warn_increase_pct, or the row's own current-period spend
--   (a real $0 counts) sits below :min_spend_usd.
-- investigate_if: CRITICAL - the increase is at/above :crit_increase_pct on at least :min_spend_usd of
--   current spend, or brand-new spend above the floor with nothing in the previous period to compare
--   against. WARN - at/above :warn_increase_pct. NOT_ASSESSED - read not_assessed_reason:
--   'previous_window_not_covered' when the account's own earliest recorded usage does not reach back
--   far enough to cover the previous window at this window length; 'current_period_unpriced' /
--   'previous_period_unpriced' when that side's whole spend could not be priced at all.
-- actions: 1) open cost_period_over_period for the same account to see which service is driving the
--   move (free); 2) open sf_chg_tag_based_allocation for the same account to see which cost center
--   or team is behind it (free); 3) if the increase is deliberate growth, set or tighten a budget
--   policy for the account before it compounds another period (config, or spend if intentional).
-- next: none
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced; previous_window_not_covered: the account's earliest usage does not reach back over the whole
--   previous window, so there is nothing honest to compare with
-- caveats: Snowflake version: one row per Snowflake account (the account plays the account's part).
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
t AS (
  SELECT SUM(IFF(period = 'current', usd, 0)) AS usd,
         SUM(IFF(period = 'previous', usd, 0)) AS prev_usd,
         COUNT_IF(rate IS NOT NULL AND period = 'current') AS priced_current_rows,
         COUNT_IF(rate IS NOT NULL AND period = 'previous') AS priced_previous_rows,
         -- a service with no price (archive tiers) is named, not a reason to judge nothing
         LISTAGG(DISTINCT IFF(rate IS NULL AND qty > 0 AND period IN ('current', 'previous'), billing_origin_product, NULL), ', ')
           AS unpriced_services,
         -- earliest usage across every service: a young account has no honest previous window
         (SELECT MIN(usage_date) FROM cost_lines WHERE qty > 0) AS first_usage_date
  FROM cost_lines
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       usd AS usd_list, 100.0 AS share_of_total_pct, prev_usd AS prev_usd_list,
       usd - prev_usd AS change_usd_list,
       IFF(prev_usd > 0, 100 * (usd - prev_usd) / prev_usd, NULL) AS change_pct,
       IFF(priced_current_rows = 0 OR priced_previous_rows = 0, 'unpriced', 'priced') AS price_basis,
       NULLIF(unpriced_services, '') AS unpriced_services,
       CASE
         WHEN first_usage_date IS NULL OR first_usage_date > DATEADD(day, -2 * :period_days, __AS_OF_DATE__) THEN 'NOT_ASSESSED'
         WHEN priced_current_rows = 0 OR priced_previous_rows = 0 THEN 'NOT_ASSESSED'
         WHEN GREATEST(usd, prev_usd) < :min_spend_usd THEN 'OK'
         WHEN prev_usd = 0 THEN 'WARN'
         WHEN 100 * (usd - prev_usd) / prev_usd >= :crit_increase_pct THEN 'CRITICAL'
         WHEN 100 * (usd - prev_usd) / prev_usd >= :warn_increase_pct THEN 'WARN'
         ELSE 'OK'
       END AS status,
       CASE WHEN first_usage_date IS NULL OR first_usage_date > DATEADD(day, -2 * :period_days, __AS_OF_DATE__) THEN 'previous_window_not_covered'
            WHEN priced_current_rows = 0 THEN 'current_period_unpriced'
            WHEN priced_previous_rows = 0 THEN 'previous_period_unpriced' END AS not_assessed_reason
FROM t
