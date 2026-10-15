-- shim: QUERY_ACCELERATION_HISTORY
-- reads: INFORMATION_SCHEMA.QUERY_ACCELERATION_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: query acceleration credits for 6 months at most; the warehouse name stands in for its id
-- QUERY_ACCELERATION_HISTORY rebuilt from INFORMATION_SCHEMA.QUERY_ACCELERATION_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(start_time AS TIMESTAMP_LTZ(9)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       CAST(credits_used AS NUMBER(38,9)) AS credits_used,
       warehouse_name AS warehouse_id,
       CAST(warehouse_name AS VARCHAR) AS warehouse_name
FROM TABLE(__INFO_SCHEMA__.QUERY_ACCELERATION_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
