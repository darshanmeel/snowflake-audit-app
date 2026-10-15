-- query_id: cost_monthly_actuals
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
