-- query_id: sf_wh_config_posture
-- title: Warehouse setup risk - auto-suspend off or too high, no resource monitor, auto-resume off,
--   Snowpark-optimized size
-- domain: compute   tier: standard
-- windowed: no
-- pre: SHOW WAREHOUSES
-- reads: SHOW WAREHOUSES, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one warehouse SHOW WAREHOUSES lists, with a posture verdict added: same
--   grain as sf_wh_config_current. The columns that matter are status (worst flag wins) and reasons
--   (every flag that fired, in one line).
-- healthy: status = OK - auto-suspend is on and 10 minutes or less, and the warehouse is tied to a
--   resource monitor. Field heuristic: pick the auto-suspend that fits your query cadence.
-- investigate_if: status = CRITICAL - auto-suspend off (NULL or 0) or above 60 minutes, so an idle
--   warehouse keeps billing. WARN - auto-suspend above 10 minutes, or no resource monitor.
--   auto-resume off and Snowpark-optimized size are named in reasons but do not change the status
--   on their own.
-- actions: 1) lower or set AUTO_SUSPEND on the flagged warehouse (60 seconds is the usual floor) so
--   it suspends when idle (free); 2) attach a resource monitor with a credit quota and notify or
--   suspend triggers (config); 3) use a Snowpark-optimized size only for memory-heavy work, since
--   it bills at a higher credit rate (spend).
-- next: none
-- caveats: flag_snowpark_optimized marks a Snowpark-optimized warehouse (higher credit rate). SHOW
--   WAREHOUSES lists only warehouses the role can see, so a row is missing for one it cannot.
WITH __INCLUDE_warehouse_config__,
f AS (
  SELECT c.*,
         -- an ADAPTIVE warehouse has no auto_suspend in SHOW, so NULL there is not 'never suspends'
         (warehouse_generation <> 'ADAPTIVE'
          AND (auto_stop_minutes IS NULL OR auto_stop_minutes = 0 OR auto_stop_minutes > 10)) AS flag_autostop_risk,
         UPPER(warehouse_type) LIKE '%SNOWPARK%' AS flag_snowpark,
         UPPER(COALESCE(auto_resume, 'true')) = 'FALSE' AS flag_no_resume,
         (resource_monitor IS NULL OR UPPER(resource_monitor) = 'NULL') AS flag_no_monitor
  FROM warehouse_config c
)
SELECT 0 AS window_days, warehouse_id, __ACCOUNT_ID__ AS account_id, warehouse_name,
       owner AS created_by, warehouse_type, warehouse_size,
       CAST(min_clusters AS INTEGER) AS min_clusters, CAST(max_clusters AS INTEGER) AS max_clusters,
       CAST(auto_stop_minutes AS INTEGER) AS auto_stop_minutes,
       flag_autostop_risk, flag_snowpark AS flag_snowpark_optimized,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(flag_autostop_risk, 'auto-suspend off or over 10 min', NULL),
         IFF(flag_no_resume, 'auto-resume off', NULL),
         IFF(flag_no_monitor, 'no resource monitor', NULL),
         IFF(flag_snowpark, 'Snowpark-optimized (higher credit rate)', NULL)), '; ') AS reasons,
       CASE
         WHEN flag_autostop_risk AND (auto_stop_minutes IS NULL OR auto_stop_minutes = 0 OR auto_stop_minutes > 60) THEN 'CRITICAL'
         WHEN flag_autostop_risk OR flag_no_monitor THEN 'WARN'
         ELSE 'OK'
       END AS status,
       updated_on AS change_time
FROM f
ORDER BY status, warehouse_name
