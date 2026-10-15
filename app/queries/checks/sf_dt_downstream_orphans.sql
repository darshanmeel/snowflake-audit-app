-- query_id: sf_dt_downstream_orphans
-- title: DOWNSTREAM-lag dynamic tables that never refresh
-- domain: jobs_pipelines   tier: standard
-- entity: dynamic tables = dt_full_name
-- windowed: yes
-- pre: SHOW DYNAMIC TABLES IN ACCOUNT
-- reads: SHOW DYNAMIC TABLES IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; SELECT on the dynamic tables (SHOW lists only
--   those); MONITOR on them for the lag and state columns
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :crit_stale_days (default 7) days since the table's data at or above which a table that does
--   not refresh reads CRITICAL
-- empty_if: role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That SHOW shows the word DOWNSTREAM in target_lag for
--   TARGET_LAG = DOWNSTREAM is assumed; the SHOW DYNAMIC TABLES page does not say.
-- not_assessed_reasons: dts_not_visible: refreshes exist in the history for dynamic tables SHOW does not
--   list (the role cannot see them, or they were dropped), so their lag is not known
-- read_this: one row = one dynamic table with TARGET_LAG = DOWNSTREAM that exists now. Such a table
--   refreshes only when a dynamic table that reads it refreshes; with no running consumer it never
--   refreshes and Snowflake gives no warning. scheduled_refreshes counts its scheduled refreshes in the
--   window; days_since_data is the age of its data (SHOW data_timestamp) at the as-of date. finding:
--   no_refresh (scheduler on, running, and no scheduled refresh in the window), manual_only (refreshed
--   only by hand or at creation), suspended (judged by sf_dt_suspended_still_read) or ok.
-- healthy: status = OK when the table refreshed on schedule in the window, is suspended, or has its
--   scheduler disabled (refreshed by hand on purpose).
-- investigate_if: WARN when a running DOWNSTREAM table had no scheduled refresh in the window; CRITICAL
--   when its data is also crit_stale_days old or older.
-- actions: 1) set a real TARGET_LAG on it if people query it directly (config); 2) point the consumer
--   that should read it back at it, or resume that consumer (free); 3) drop it if nothing needs it (free)
-- next: sf_dt_refresh_failures_and_lag, sf_dt_suspended_still_read
-- caveats: The cheap signal is the symptom (no scheduled refresh), not the dependency graph: a consumer
--   that exists but is suspended reads the same. SHOW state and data_timestamp are current at the export;
--   the age is counted to the as-of date. The refresh history lags up to 3 hours.
WITH __INCLUDE_sf_dt_dim__,
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
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
