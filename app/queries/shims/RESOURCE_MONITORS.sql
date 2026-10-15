-- shim: RESOURCE_MONITORS
-- reads: SHOW RESOURCE MONITORS
-- show: SHOW RESOURCE MONITORS
-- needs: MANAGE GRANTS
-- note: the warehouses a monitor is set on are not listed; the name stands in for the id
-- RESOURCE_MONITORS rebuilt from SHOW RESOURCE MONITORS: each column taken by name, mapped, or NULL where the source has none.
SELECT "name" AS resource_monitor_id,
       CAST("name" AS VARCHAR) AS name,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created,
       TO_VARIANT(TRY_TO_NUMBER("credit_quota"::STRING, 38, 2)) AS credit_quota,
       TO_VARIANT(TRY_TO_NUMBER("used_credits"::STRING, 38, 2)) AS used_credits,
       CAST(TRY_TO_DOUBLE("remaining_credits"::STRING) AS FLOAT) AS remaining_credits,
       CAST("owner" AS VARCHAR) AS owner,
       CAST(TRY_TO_NUMBER(REPLACE(SPLIT_PART("notify_at", ',', 1), '%', '')) AS NUMBER(38,0)) AS notify,
       CAST(TRY_TO_NUMBER(REPLACE("suspend_at", '%', '')) AS NUMBER(38,0)) AS suspend,
       CAST(TRY_TO_NUMBER(REPLACE("suspend_immediately_at", '%', '')) AS NUMBER(38,0)) AS suspend_immediate,
       CAST(NULL AS VARCHAR) AS warehouses
FROM __SHOW__
