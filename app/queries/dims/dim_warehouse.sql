-- Latest name per warehouse id seen in metering history.
SELECT __ACCOUNT_ID__ AS account_id, TO_VARCHAR(warehouse_id) AS warehouse_id,
       MAX_BY(warehouse_name, start_time) AS warehouse_name
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD(day, -400, __AS_OF_DATE__)
GROUP BY warehouse_id
