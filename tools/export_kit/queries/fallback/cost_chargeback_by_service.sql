-- query_id: cost_chargeback_by_service
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
