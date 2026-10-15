-- Share of the window's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- A per-query cloud services credit is before that adjustment, so a billed figure is credits * billed_ratio.
sf_cs_window AS (
  SELECT COALESCE(GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
                    / NULLIF(SUM(credits_used_cloud_services), 0), 1) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
)