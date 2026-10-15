-- query_id: sf_cost_month_end_forecast
-- shims: METERING_DAILY_HISTORY, STORAGE_USAGE, DATA_TRANSFER_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY, DATABASE_STORAGE_USAGE_HISTORY, STAGE_STORAGE_USAGE_HISTORY, DATA_TRANSFER_HISTORY
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule; storage for 6 months at most; no hybrid table or archive storage; data transfer for the last 14 days at most
-- needs: MONITOR USAGE
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
    FROM __SHIM_METERING_DAILY_HISTORY__
    WHERE usage_date >= DATEADD(day, -400, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
    UNION ALL
    SELECT usage_date, 'STORAGE', 'STORAGE', 'STORAGE_SPACE', 'TB_DAYS',
           (COALESCE(storage_bytes, 0) + COALESCE(stage_bytes, 0) + COALESCE(failsafe_bytes, 0)
            + COALESCE(hybrid_table_storage_bytes, 0)) / POWER(1024, 4),
           __STORAGE_PRICE_TB_MONTH__ / 30.4
    FROM __SHIM_STORAGE_USAGE__
    WHERE usage_date >= DATEADD(day, -400, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
    UNION ALL
    -- Archive tiers have their own rate that the app does not know: NULL rate = unpriced, never $0.
    SELECT usage_date, 'STORAGE_ARCHIVE', 'STORAGE_ARCHIVE', 'STORAGE_SPACE', 'TB_DAYS',
           (COALESCE(archive_storage_cool_bytes, 0) + COALESCE(archive_storage_cold_bytes, 0)) / POWER(1024, 4),
           CAST(NULL AS DOUBLE)
    FROM __SHIM_STORAGE_USAGE__
    WHERE usage_date >= DATEADD(day, -400, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
      AND COALESCE(archive_storage_cool_bytes, 0) + COALESCE(archive_storage_cold_bytes, 0) > 0
    UNION ALL
    -- Estimated like sf_cost_data_transfer_egress (same per-TB rates). The view lists only transfer out of
    -- the region (same-region transfer is free and has no row): another region of the same cloud, or another cloud.
    SELECT CAST(start_time AS DATE), 'DATA_TRANSFER', 'DATA_TRANSFER', 'DATA_TRANSFER', 'TB',
           SUM(TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred))) / POWER(1024, 4),
           IFF(COALESCE(UPPER(target_cloud) = UPPER(source_cloud), FALSE), 20, 90)
    FROM __SHIM_DATA_TRANSFER_HISTORY__
    WHERE start_time >= DATEADD(day, -400, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    GROUP BY CAST(start_time AS DATE), COALESCE(UPPER(target_cloud) = UPPER(source_cloud), FALSE)
  ) x
),
b AS (
  SELECT DATE_TRUNC('month', DATEADD(day, -1, __AS_OF_DATE__)) AS month_start
),
first_day AS (
  SELECT MIN(usage_date) AS first_usage_date FROM __SHIM_METERING_DAILY_HISTORY__
),
cal AS (
  SELECT month_start, DATEADD(month, -1, month_start) AS prev_month_start,
         DAY(LAST_DAY(month_start)) AS days_in_month,
         DAY(LAST_DAY(DATEADD(month, -1, month_start))) AS days_in_last_month,
         -- a young account has fewer days than the run-rate window; zero-usage days inside it still count
         GREATEST(LEAST(:run_rate_days, DATEDIFF(day, f.first_usage_date, __AS_OF_DATE__)), 1) AS rate_days,
         f.first_usage_date,
         DATEDIFF(day, month_start, __AS_OF_DATE__) AS days_elapsed
  FROM b CROSS JOIN first_day f
),
l AS (
  SELECT c.billing_origin_product, c.usd, c.rate,
         IFF(c.usage_unit = 'CREDITS', c.qty, NULL) AS credits,
         c.usage_date >= cal.month_start AS in_mtd,
         c.usage_date >= DATEADD(day, -:run_rate_days, __AS_OF_DATE__) AS in_rate,
         c.usage_date >= cal.prev_month_start AND c.usage_date < cal.month_start AS in_last
  FROM cost_lines c
  CROSS JOIN cal
  WHERE c.usage_date >= LEAST(cal.prev_month_start, DATEADD(day, -:run_rate_days, __AS_OF_DATE__))
),
m AS (
  SELECT COALESCE(l.billing_origin_product, 'TOTAL') AS service_type,
         -- credits only where the row has credit lines; storage and transfer rows read NULL, never 0
         IFF(COUNT(l.credits) > 0, SUM(IFF(l.in_mtd, l.credits, 0)), NULL) AS mtd_credits,
         IFF(COUNT(l.credits) > 0, SUM(IFF(l.in_rate, l.credits, 0)), NULL) / MAX(cal.rate_days) AS daily_rate,
         IFF(COUNT(l.credits) > 0, SUM(IFF(l.in_last, l.credits, 0)), NULL) AS last_month_credits,
         -- an unpriced line (NULL rate) is left out of the $, never counted as $0
         IFF(COUNT(l.rate) > 0, SUM(IFF(l.in_mtd, COALESCE(l.usd, 0), 0)), NULL) AS mtd_usd,
         IFF(COUNT(l.rate) > 0, SUM(IFF(l.in_rate, COALESCE(l.usd, 0), 0)), NULL) / MAX(cal.rate_days) AS daily_rate_usd,
         IFF(COUNT(l.rate) > 0, SUM(IFF(l.in_last, COALESCE(l.usd, 0), 0)), NULL) AS last_month_usd,
         MAX(cal.days_in_month) AS days_in_month, MAX(cal.days_in_last_month) AS days_in_last_month,
         MAX(cal.days_elapsed) AS days_elapsed, MAX(cal.prev_month_start) AS prev_month_start,
         MAX(cal.first_usage_date) AS first_usage_date
  FROM l
  CROSS JOIN cal
  GROUP BY GROUPING SETS ((l.billing_origin_product), ())
),
s AS (
  SELECT m.*,
         mtd_credits + daily_rate * GREATEST(days_in_month - days_elapsed, 0) AS projected_credits,
         mtd_usd + daily_rate_usd * GREATEST(days_in_month - days_elapsed, 0) AS projected_usd,
         -- TOTAL is unpriced without a credit price, so it is never judged on storage alone
         mtd_usd IS NULL OR (service_type = 'TOTAL' AND __CREDIT_PRICE__ IS NULL) AS unpriced
  FROM m
),
p AS (
  SELECT s.*,
         -- per-day comparison, so a 28-day month is not read as lower than a 31-day one; $ when priced
         COALESCE(
           100 * (projected_usd / days_in_month - last_month_usd / days_in_last_month)
             / NULLIF(last_month_usd / days_in_last_month, 0),
           100 * (projected_credits / days_in_month - last_month_credits / days_in_last_month)
             / NULLIF(last_month_credits / days_in_last_month, 0)) AS vs_last_month_pct,
         first_usage_date > prev_month_start AS last_month_not_covered,
         days_elapsed < :min_days_elapsed AS too_early,
         COALESCE(service_type = 'TOTAL' AND :monthly_budget_usd > 0 AND projected_usd > :monthly_budget_usd, FALSE) AS over_budget
  FROM s
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, service_type, service_type = 'TOTAL' AS is_total_row, days_elapsed, days_in_month, days_in_last_month,
       days_elapsed < days_in_month AS is_partial_month,
       IFF(days_elapsed < days_in_month, 'month_in_progress', NULL) AS partial_reason,
       mtd_credits AS month_to_date_credits, daily_rate AS daily_run_rate_credits,
       projected_credits, last_month_credits, vs_last_month_pct,
       IFF(unpriced, NULL, mtd_usd) AS est_month_to_date_usd_list,
       IFF(unpriced, NULL, daily_rate_usd) AS est_daily_run_rate_usd_list,
       IFF(unpriced, NULL, projected_usd) AS est_projected_usd_list,
       IFF(unpriced, NULL, last_month_usd) AS est_last_month_usd_list,
       IFF(service_type = 'TOTAL' AND :monthly_budget_usd > 0, :monthly_budget_usd, NULL) AS monthly_budget_usd,
       IFF(unpriced, 'unpriced', 'priced') AS price_basis,
       CASE WHEN unpriced THEN 'unpriced'
            WHEN NOT over_budget AND projected_usd >= :min_spend_usd AND last_month_not_covered THEN 'last_month_not_covered'
            WHEN NOT over_budget AND projected_usd >= :min_spend_usd AND too_early THEN 'too_early_in_month' END AS not_assessed_reason,
       CASE
         WHEN unpriced THEN 'NOT_ASSESSED'
         WHEN over_budget THEN 'CRITICAL'
         WHEN projected_usd < :min_spend_usd THEN 'OK'
         WHEN last_month_not_covered OR too_early THEN 'NOT_ASSESSED'
         WHEN last_month_usd = 0 THEN 'WARN'
         WHEN vs_last_month_pct >= :crit_over_pct THEN 'CRITICAL'
         WHEN vs_last_month_pct >= :warn_over_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM p
ORDER BY service_type = 'TOTAL' DESC, IFF(unpriced, NULL, projected_usd) DESC NULLS LAST, projected_credits DESC
