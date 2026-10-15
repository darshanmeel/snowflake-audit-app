-- query_id: cost_daily_spikes
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
