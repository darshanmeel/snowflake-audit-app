-- query_id: sf_dt_suspended_still_read
-- title: Suspended dynamic tables that are still read
-- domain: jobs_pipelines   tier: standard
-- entity: dynamic tables = dt_full_name
-- windowed: yes
-- pre: SHOW DYNAMIC TABLES IN ACCOUNT
-- reads: SHOW DYNAMIC TABLES IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; SELECT on the dynamic tables (SHOW lists only
--   those); Enterprise Edition for the reads (ACCESS_HISTORY)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- empty_if: role_cannot_see, view_missing, edition_too_low, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That a table's own refresh lists it in ACCESS_HISTORY, so its
--   refresh queries are left out of the reads, is taken from the dynamic tables cost check. How ACCESS_HISTORY
--   behaves on Standard edition (empty or an error) is not stated; an error fails the check.
-- not_assessed_reasons: dts_not_visible: refreshes exist in the history for dynamic tables SHOW does not list
--   (the role cannot see them, or they were dropped), so their state is not known
-- read_this: one row = one dynamic table that exists now. suspended_since is when it was last suspended (SHOW,
--   current at the export). read_queries counts queries that read it after the suspension, or in the window
--   if it has no suspension time, its own refresh and the refresh of other tables apart; it is empty without
--   ACCESS_HISTORY. finding is suspended_and_read, suspended_unread, suspended_reads_unknown or ok. Lag and
--   full-refresh mode are judged in sf_dt_refresh_failures_and_lag.
-- healthy: status = OK when the table is running, refreshed by hand (scheduler disabled), or suspended and
--   nobody reads it.
-- investigate_if: WARN when a suspended table is unread, or cannot be checked for reads; CRITICAL when a
--   suspended table is read after it was suspended (consumers get stale data).
-- actions: 1) ALTER DYNAMIC TABLE ... RESUME if it is still needed, and fix what suspended it (free);
--   2) drop a suspended table nobody reads (config).
-- next: sf_dt_refresh_failures_and_lag, sf_dt_cost
-- caveats: A table with the scheduler disabled is refreshed by hand: it is not judged as suspended. SHOW state
--   is current at the export, not at the as-of date; reads are counted only up to the as-of date. Reads
--   are queries of any user, base tables behind views included. Refresh cost stays on the dynamic table cost
--   check. Without ACCESS_HISTORY (Standard edition) reads are unknown and a suspended table reads WARN.
WITH -- Current table id of each live table by full name, for dynamic tables whose refresh history
-- carries names only. Dropped tables have no id here, so their rows keep the name alone.
sf_dt_dim AS (
  SELECT table_catalog || '.' || table_schema || '.' || table_name AS dt_full_name,
         MAX(TO_VARCHAR(table_id)) AS dt_id, MAX(table_owner) AS owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  GROUP BY 1
),
sd AS (
  SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS dt_full_name, "name" AS dt_name,
         "database_name" AS database_name, "schema_name" AS schema_name, "owner" AS dt_owner,
         "warehouse" AS warehouse_name, "target_lag" AS target_lag,
         UPPER(TO_VARCHAR(COALESCE("scheduler", 'ENABLE'))) AS scheduler,
         UPPER(TO_VARCHAR("scheduling_state")) AS scheduling_state,
         CAST("last_suspended_on" AS TIMESTAMP_LTZ) AS suspended_since
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
),
sus AS (
  SELECT dt_full_name, suspended_since FROM sd WHERE scheduling_state = 'SUSPENDED' AND scheduler <> 'DISABLE'
),
rq AS (
  SELECT DISTINCT query_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
  WHERE query_id IS NOT NULL
    AND data_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND data_timestamp < __AS_OF_DATE__
),
rd AS (
  -- Only the suspended tables are kept after the flatten, so the grouping stays small.
  SELECT UPPER(f.value:"objectName"::VARCHAR) AS name_key, ah.query_id, ah.query_start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT())), OUTER => TRUE) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND ah.query_start_time < __AS_OF_DATE__
    AND ah.query_id NOT IN (SELECT query_id FROM rq)
    AND UPPER(f.value:"objectName"::VARCHAR) IN (SELECT UPPER(dt_full_name) FROM sus)
),
rc AS (
  SELECT sus.dt_full_name, COUNT(DISTINCT rd.query_id) AS read_queries
  FROM sus
  JOIN rd ON rd.name_key = UPPER(sus.dt_full_name)
         AND rd.query_start_time >= COALESCE(sus.suspended_since, DATEADD(day, -:period_days, __AS_OF_DATE__))
  GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM (
    SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
    WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
    LIMIT 1)
),
hn AS (
  SELECT database_name || '.' || schema_name || '.' || name AS dt_full_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
  WHERE data_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND data_timestamp < __AS_OF_DATE__
  GROUP BY 1
),
s AS (
  SELECT sd.*, d.dt_id,
         sd.scheduling_state = 'SUSPENDED' AND sd.scheduler <> 'DISABLE' AS is_suspended,
         IFF(seen.access_rows = 0, NULL, COALESCE(rc.read_queries, 0)) AS read_queries
  FROM sd
  LEFT JOIN sf_dt_dim d ON d.dt_full_name = sd.dt_full_name
  LEFT JOIN rc ON rc.dt_full_name = sd.dt_full_name
  CROSS JOIN seen
),
f AS (
  SELECT s.*, is_suspended AND COALESCE(read_queries, 0) > 0 AS susp_read,
         is_suspended AND read_queries = 0 AS susp_unread,
         is_suspended AND read_queries IS NULL AS susp_unknown
  FROM s
),
main AS (
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, dt_full_name, dt_name, dt_id, database_name, schema_name,
         dt_owner, warehouse_name, target_lag, scheduler, scheduling_state, suspended_since, read_queries,
         CASE WHEN susp_read THEN 'suspended_and_read' WHEN susp_unread THEN 'suspended_unread'
              WHEN susp_unknown THEN 'suspended_reads_unknown' ELSE 'ok' END AS finding,
         ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           IFF(susp_read, 'suspended and read by ' || read_queries || ' queries', NULL),
           IFF(susp_unread, 'suspended and not read', NULL),
           IFF(susp_unknown, 'suspended; reads unknown without ACCESS_HISTORY', NULL),
           IFF(scheduler = 'DISABLE', 'scheduler disabled (manual refresh)', NULL)), '; ') AS reasons,
         CAST(NULL AS VARCHAR) AS not_assessed_reason,
         CASE WHEN susp_read THEN 'CRITICAL' WHEN susp_unread OR susp_unknown THEN 'WARN' ELSE 'OK' END AS status
  FROM f
),
blind AS (
  -- Refreshes exist for tables SHOW does not list: the role cannot see them (or they were dropped).
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
         CAST('(' || COUNT(*) || ' dynamic tables in the history not listed by SHOW)' AS VARCHAR) AS dt_full_name,
         CAST(NULL AS VARCHAR) AS dt_name, CAST(NULL AS VARCHAR) AS dt_id, CAST(NULL AS VARCHAR) AS database_name,
         CAST(NULL AS VARCHAR) AS schema_name, CAST(NULL AS VARCHAR) AS dt_owner, CAST(NULL AS VARCHAR) AS warehouse_name,
         CAST(NULL AS VARCHAR) AS target_lag, CAST(NULL AS VARCHAR) AS scheduler, CAST(NULL AS VARCHAR) AS scheduling_state,
         CAST(NULL AS TIMESTAMP_LTZ) AS suspended_since, CAST(NULL AS NUMBER) AS read_queries, CAST(NULL AS VARCHAR) AS finding,
         CAST(NULL AS VARCHAR) AS reasons, 'dts_not_visible' AS not_assessed_reason, 'NOT_ASSESSED' AS status
  FROM hn
  WHERE hn.dt_full_name NOT IN (SELECT dt_full_name FROM sd)
  HAVING COUNT(*) > 0
)
SELECT * FROM (
  SELECT * FROM main
  UNION ALL
  SELECT * FROM blind
)
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END, read_queries DESC NULLS LAST, dt_full_name
