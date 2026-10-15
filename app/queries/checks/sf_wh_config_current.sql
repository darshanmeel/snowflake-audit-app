-- query_id: sf_wh_config_current
-- title: Warehouse configuration (current)
-- domain: compute   tier: lite
-- windowed: no
-- pre: SHOW WAREHOUSES
-- reads: SHOW WAREHOUSES, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one warehouse SHOW WAREHOUSES lists now. The columns that matter are
--   warehouse_size, min_clusters/max_clusters (multi-cluster bounds) and auto_stop_minutes (how
--   long the warehouse waits before suspending). warehouse_generation is GEN1, GEN2, SNOWPARK_OPTIMIZED or
--   ADAPTIVE and credits_per_hour is the Service Consumption Table rate for it (an estimate input, not
--   billed spend; NULL for adaptive, which has no fixed rate).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Tags come from TAG_REFERENCES (see access_tags_inventory). SHOW WAREHOUSES lists only
--   warehouses the role can see.
WITH __INCLUDE_warehouse_config__
SELECT 0 AS window_days, warehouse_id, warehouse_name, __ACCOUNT_ID__ AS account_id,
       warehouse_type, warehouse_generation, resource_constraint, credits_per_hour,
       warehouse_size, CAST(min_clusters AS INTEGER) AS min_clusters,
       CAST(max_clusters AS INTEGER) AS max_clusters, CAST(auto_stop_minutes AS INTEGER) AS auto_stop_minutes,
       CAST(NULL AS VARCHAR) AS tags, updated_on AS change_time, CAST(NULL AS TIMESTAMP) AS delete_time
FROM warehouse_config
ORDER BY warehouse_name
