-- shim: METERING_DAILY_HISTORY
-- reads: INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY (table functions)
-- needs: MONITOR USAGE
-- note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule
-- METERING_DAILY_HISTORY rebuilt from the metering table functions, one row per service type and day.
-- The daily cloud-services adjustment (cloud services up to 10% of the day's compute are free) sits on
-- the WAREHOUSE_METERING row, so credits_billed adds up to the bill for these services.
SELECT service_type, usage_date, credits_used_compute, credits_used_cloud_services, credits_used,
       IFF(service_type = 'WAREHOUSE_METERING', -LEAST(day_cloud, 0.1 * day_compute), 0) AS credits_adjustment_cloud_services,
       credits_used + IFF(service_type = 'WAREHOUSE_METERING', -LEAST(day_cloud, 0.1 * day_compute), 0) AS credits_billed
FROM (
  SELECT service_type, usage_date, credits_used_compute, credits_used_cloud_services,
         credits_used_compute + credits_used_cloud_services AS credits_used,
         SUM(credits_used_cloud_services) OVER (PARTITION BY usage_date) AS day_cloud,
         SUM(credits_used_compute) OVER (PARTITION BY usage_date) AS day_compute
  FROM (
    SELECT service_type, CAST(start_time AS DATE) AS usage_date,
           SUM(CAST(compute AS NUMBER(38, 9))) AS credits_used_compute,
           SUM(CAST(cloud AS NUMBER(38, 9))) AS credits_used_cloud_services
    FROM (
      SELECT 'WAREHOUSE_METERING' AS service_type, start_time, credits_used_compute AS compute, credits_used_cloud_services AS cloud
      FROM TABLE(__INFO_SCHEMA__.WAREHOUSE_METERING_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
      UNION ALL
      SELECT 'AUTO_CLUSTERING', start_time, credits_used, 0
      FROM TABLE(__INFO_SCHEMA__.AUTOMATIC_CLUSTERING_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
      UNION ALL
      SELECT 'MATERIALIZED_VIEW', start_time, credits_used, 0
      FROM TABLE(__INFO_SCHEMA__.MATERIALIZED_VIEW_REFRESH_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
      UNION ALL
      SELECT 'SEARCH_OPTIMIZATION', start_time, credits_used, 0
      FROM TABLE(__INFO_SCHEMA__.SEARCH_OPTIMIZATION_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
      UNION ALL
      SELECT 'SERVERLESS_TASK', start_time, credits_used, 0
      FROM TABLE(__INFO_SCHEMA__.SERVERLESS_TASK_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
      UNION ALL
      SELECT 'PIPE', start_time, credits_used, 0
      FROM TABLE(__INFO_SCHEMA__.PIPE_USAGE_HISTORY(DATE_RANGE_START => __SHIM_14_DAYS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
      UNION ALL
      SELECT 'QUERY_ACCELERATION', start_time, credits_used, 0
      FROM TABLE(__INFO_SCHEMA__.QUERY_ACCELERATION_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
      UNION ALL
      SELECT 'REPLICATION', start_time, credits_used, 0
      FROM TABLE(__INFO_SCHEMA__.REPLICATION_GROUP_USAGE_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
      UNION ALL
      SELECT 'SERVERLESS_ALERTS', start_time, credits_used, 0
      FROM TABLE(__INFO_SCHEMA__.SERVERLESS_ALERT_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
    ) m
    GROUP BY 1, 2
  ) d
) a
