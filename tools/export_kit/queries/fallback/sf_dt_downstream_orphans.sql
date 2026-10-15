-- query_id: sf_dt_downstream_orphans
-- shims: TABLES, DYNAMIC_TABLE_REFRESH_HISTORY
-- reads: INFORMATION_SCHEMA table functions TABLES (view, per database), DYNAMIC_TABLE_REFRESH_HISTORY
-- fallback_note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; refreshes for the last 7 days, the latest 10,000 at most, only dynamic tables this role can monitor
-- pre: SHOW DYNAMIC TABLES IN ACCOUNT
WITH -- Current table id of each live table by full name, for dynamic tables whose refresh history
-- carries names only. Dropped tables have no id here, so their rows keep the name alone.
sf_dt_dim AS (
  SELECT table_catalog || '.' || table_schema || '.' || table_name AS dt_full_name,
         MAX(TO_VARCHAR(table_id)) AS dt_id, MAX(table_owner) AS owner
  FROM __SHIM_TABLES__
  WHERE deleted IS NULL
  GROUP BY 1
),
sd AS (
  SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS dt_full_name, "name" AS dt_name,
         "database_name" AS database_name, "schema_name" AS schema_name, "owner" AS dt_owner,
         "warehouse" AS warehouse_name, TO_VARCHAR("target_lag") AS target_lag,
         UPPER(TO_VARCHAR(COALESCE("scheduler", 'ENABLE'))) AS scheduler,
         UPPER(TO_VARCHAR("scheduling_state")) AS scheduling_state,
         CAST("data_timestamp" AS TIMESTAMP_LTZ) AS data_timestamp,
         CAST("created_on" AS TIMESTAMP_LTZ) AS created_on
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
),
hist AS (
  SELECT database_name || '.' || schema_name || '.' || name AS dt_full_name,
         COUNT_IF(refresh_trigger = 'SCHEDULED') AS scheduled_refreshes,
         COUNT_IF(refresh_trigger IN ('MANUAL', 'CREATION')) AS manual_refreshes,
         MAX(refresh_start_time) AS last_refresh_time,
         MAX(IFF(refresh_trigger = 'SCHEDULED', refresh_start_time, NULL)) AS last_scheduled_refresh
  FROM __SHIM_DYNAMIC_TABLE_REFRESH_HISTORY__
  WHERE refresh_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND refresh_start_time < __AS_OF_DATE__
  GROUP BY 1
),
s AS (
  SELECT sd.*, d.dt_id, COALESCE(h.scheduled_refreshes, 0) AS scheduled_refreshes,
         COALESCE(h.manual_refreshes, 0) AS manual_refreshes, h.last_refresh_time, h.last_scheduled_refresh,
         GREATEST(DATEDIFF(day, sd.data_timestamp, __AS_OF_DATE__), 0) AS days_since_data
  FROM sd
  LEFT JOIN sf_dt_dim d ON d.dt_full_name = sd.dt_full_name
  LEFT JOIN hist h ON h.dt_full_name = sd.dt_full_name
  WHERE UPPER(sd.target_lag) LIKE '%DOWNSTREAM%'
),
f AS (
  SELECT s.*,
         CASE WHEN scheduler = 'DISABLE' THEN 'ok'
              WHEN scheduling_state = 'SUSPENDED' THEN 'suspended'
              WHEN scheduled_refreshes > 0 THEN 'ok'
              WHEN manual_refreshes > 0 THEN 'manual_only'
              ELSE 'no_refresh' END AS finding
  FROM s
),
main AS (
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, dt_full_name, dt_name, dt_id, database_name,
         schema_name, dt_owner, warehouse_name, target_lag, scheduler, scheduling_state, created_on, data_timestamp,
         days_since_data, scheduled_refreshes, manual_refreshes, last_refresh_time, last_scheduled_refresh, finding,
         CAST(NULL AS VARCHAR) AS not_assessed_reason,
         CASE WHEN finding IN ('no_refresh', 'manual_only') AND days_since_data >= :crit_stale_days THEN 'CRITICAL'
              WHEN finding IN ('no_refresh', 'manual_only') THEN 'WARN'
              ELSE 'OK' END AS status
  FROM f
),
hn AS (
  SELECT database_name || '.' || schema_name || '.' || name AS dt_full_name
  FROM __SHIM_DYNAMIC_TABLE_REFRESH_HISTORY__
  WHERE refresh_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND refresh_start_time < __AS_OF_DATE__
  GROUP BY 1
),
blind AS (
  -- Refreshes exist for tables SHOW does not list: the role cannot see them (or they were dropped).
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
         CAST('(' || COUNT(*) || ' dynamic tables in the history not listed by SHOW)' AS VARCHAR) AS dt_full_name,
         CAST(NULL AS VARCHAR) AS dt_name, CAST(NULL AS VARCHAR) AS dt_id, CAST(NULL AS VARCHAR) AS database_name,
         CAST(NULL AS VARCHAR) AS schema_name, CAST(NULL AS VARCHAR) AS dt_owner, CAST(NULL AS VARCHAR) AS warehouse_name,
         CAST(NULL AS VARCHAR) AS target_lag, CAST(NULL AS VARCHAR) AS scheduler, CAST(NULL AS VARCHAR) AS scheduling_state,
         CAST(NULL AS TIMESTAMP_LTZ) AS created_on, CAST(NULL AS TIMESTAMP_LTZ) AS data_timestamp,
         CAST(NULL AS NUMBER) AS days_since_data, CAST(NULL AS NUMBER) AS scheduled_refreshes,
         CAST(NULL AS NUMBER) AS manual_refreshes, CAST(NULL AS TIMESTAMP_LTZ) AS last_refresh_time,
         CAST(NULL AS TIMESTAMP_LTZ) AS last_scheduled_refresh, CAST(NULL AS VARCHAR) AS finding,
         'dts_not_visible' AS not_assessed_reason, 'NOT_ASSESSED' AS status
  FROM hn
  WHERE hn.dt_full_name NOT IN (SELECT dt_full_name FROM sd)
  HAVING COUNT(*) > 0
)
SELECT * FROM (
  SELECT * FROM main
  UNION ALL
  SELECT * FROM blind
)
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END,
         days_since_data DESC NULLS LAST, dt_full_name
