-- windowed: yes
-- Billed credits per service type (METERING_DAILY_HISTORY, after the cloud services adjustment): the
-- whole bill, of which WAREHOUSE_METERING is what the warehouse rows above split.
SELECT :period_days AS window_days, service_type, SUM(credits_billed) AS credits_billed
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
GROUP BY service_type
