-- shim: WAREHOUSE_METERING_HISTORY
-- reads: INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: warehouse credits for 6 months at most; adaptive warehouses left out; the warehouse name stands in for its id; no per-query attribution
-- One row per warehouse and hour. CREDITS_ATTRIBUTED_COMPUTE_QUERIES is not in the table function: NULL,
-- which the checks read as "not assessed", never as idle.
SELECT start_time, end_time, warehouse_name AS warehouse_id, warehouse_name, credits_used, credits_used_compute,
       credits_used_cloud_services, CAST(NULL AS NUMBER(38, 9)) AS credits_attributed_compute_queries
FROM TABLE(__INFO_SCHEMA__.WAREHOUSE_METERING_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
