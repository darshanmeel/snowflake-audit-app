-- shim: WAREHOUSE_LOAD_HISTORY
-- reads: INFORMATION_SCHEMA.WAREHOUSE_LOAD_HISTORY (table function, per warehouse)
-- each: warehouse
-- note: warehouse load for the last 14 days only, for the warehouses this role can see; the name stands in for the warehouse id
-- columns: START_TIME TIMESTAMP_LTZ(6), END_TIME TIMESTAMP_LTZ(9), WAREHOUSE_ID VARCHAR, WAREHOUSE_NAME VARCHAR, AVG_RUNNING NUMBER(38,9), AVG_QUEUED_LOAD NUMBER(38,9), AVG_QUEUED_PROVISIONING NUMBER(38,9), AVG_BLOCKED NUMBER(38,9)
-- WAREHOUSE_LOAD_HISTORY rebuilt from INFORMATION_SCHEMA.WAREHOUSE_LOAD_HISTORY (table function, per warehouse): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(start_time AS TIMESTAMP_LTZ(6)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       warehouse_name AS warehouse_id,
       CAST(warehouse_name AS VARCHAR) AS warehouse_name,
       CAST(avg_running AS NUMBER(38,9)) AS avg_running,
       CAST(avg_queued_load AS NUMBER(38,9)) AS avg_queued_load,
       CAST(avg_queued_provisioning AS NUMBER(38,9)) AS avg_queued_provisioning,
       CAST(avg_blocked AS NUMBER(38,9)) AS avg_blocked
FROM TABLE(__INFO_SCHEMA__.WAREHOUSE_LOAD_HISTORY(DATE_RANGE_START => DATEADD(day, -14, CURRENT_DATE()), DATE_RANGE_END => CURRENT_TIMESTAMP(), WAREHOUSE_NAME => __ITEM_LITERAL__))
