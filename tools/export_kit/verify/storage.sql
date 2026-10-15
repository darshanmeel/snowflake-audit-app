-- Test queries: Storage. Read-only (SELECT and WITH only); paste one at a time into a worksheet.
-- Each recomputes a figure the app shows, straight from SNOWFLAKE.ACCOUNT_USAGE, so you can compare.
-- usd_per_tb_month = your storage price; storage figures are $ per month, never added to window $.

-- 1. Dropped tables still billed, and the part a drop can free now (Storage > Unused;
--    check sf_storage_dropped_not_purged). Only clone-retained bytes can go early; Time Travel and
--    Fail-safe of a dropped table age out by themselves. Fail-safe rows can have no name.
WITH p AS (SELECT 23.00 AS usd_per_tb_month)
SELECT COALESCE(table_catalog || '.' || table_schema || '.' || table_name, 'Fail-safe table (' || id || ')') AS table_name,
       id AS table_id,
       ROUND((active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes) / POWER(1024, 3), 1) AS billed_gb,
       ROUND((active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes) / POWER(1024, 4) * p.usd_per_tb_month, 2) AS usd_month,
       ROUND(retained_for_clone_bytes / POWER(1024, 4) * p.usd_per_tb_month, 2) AS freeable_usd_month
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, p
WHERE COALESCE(deleted, FALSE) OR table_dropped IS NOT NULL OR schema_dropped IS NOT NULL
   OR catalog_dropped IS NOT NULL OR table_entered_failsafe IS NOT NULL OR table_name IS NULL
ORDER BY billed_gb DESC
LIMIT 50;

-- 2. Fail-safe on permanent tables (Storage > Time Travel & Fail-safe; check sf_storage_failsafe_on_staging).
--    The saving of making a table transient is its Fail-safe bytes only.
WITH p AS (SELECT 23.00 AS usd_per_tb_month)
SELECT table_catalog || '.' || table_schema || '.' || table_name AS table_name, id AS table_id,
       ROUND(failsafe_bytes / POWER(1024, 3), 1) AS failsafe_gb,
       ROUND(failsafe_bytes / POWER(1024, 4) * p.usd_per_tb_month, 2) AS failsafe_usd_month
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, p
WHERE NOT COALESCE(deleted, FALSE) AND table_name IS NOT NULL AND is_transient = 'NO' AND failsafe_bytes > 0
ORDER BY failsafe_bytes DESC
LIMIT 50;

-- 3. Time Travel on tables that keep more than 1 day (Storage > Time Travel & Fail-safe;
--    check sf_storage_time_travel_heavy). A table already at 1 day reads OK: nothing to shorten.
WITH p AS (SELECT 23.00 AS usd_per_tb_month)
SELECT m.table_catalog || '.' || m.table_schema || '.' || m.table_name AS table_name, m.id AS table_id,
       t.retention_time AS retention_days,
       ROUND(m.time_travel_bytes / POWER(1024, 3), 1) AS time_travel_gb,
       ROUND(m.time_travel_bytes / POWER(1024, 4) * p.usd_per_tb_month, 2) AS tt_usd_month,
       ROUND(m.time_travel_bytes / POWER(1024, 4) * p.usd_per_tb_month * (1 - 1 / t.retention_time), 2) AS saving_if_1_day_usd_month
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS m
JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t ON t.table_id = m.id AND t.deleted IS NULL, p
WHERE NOT COALESCE(m.deleted, FALSE) AND m.time_travel_bytes > 0 AND t.retention_time > 1
ORDER BY m.time_travel_bytes DESC
LIMIT 50;

-- 4. Stage storage: the account total and the per-stage view on their latest day should be close
--    (Storage > Growth & stages; checks sf_storage_stage_bytes and sf_storage_stale_stage_files).
--    The per-stage view is best effort and lags up to 2 days, so compare the same day.
WITH d AS (
  SELECT MAX(usage_date) AS day FROM SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_DETAILS
)
SELECT d.day,
       (SELECT ROUND(SUM(bytes) / POWER(1024, 4), 2) FROM SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_DETAILS s
        WHERE s.usage_date = d.day) AS per_stage_tb,
       (SELECT ROUND(SUM(average_stage_bytes) / POWER(1024, 4), 2) FROM SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_HISTORY h
        WHERE h.usage_date = d.day) AS account_total_tb
FROM d;

-- 5. Tables nobody read in 90 days, clones left out (Storage > Unused; check sf_storage_unused_tables;
--    clones are judged under unread clones). Needs Enterprise edition (ACCESS_HISTORY).
WITH reads AS (
  SELECT DISTINCT o.value:"objectId"::NUMBER AS table_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY a, LATERAL FLATTEN(input => a.base_objects_accessed) o
  WHERE a.query_start_time >= DATEADD(day, -90, CURRENT_DATE())
)
SELECT m.table_catalog || '.' || m.table_schema || '.' || m.table_name AS table_name, m.id AS table_id,
       ROUND(m.active_bytes / POWER(1024, 3), 1) AS active_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS m
LEFT JOIN reads r ON r.table_id = m.id
WHERE NOT COALESCE(m.deleted, FALSE) AND m.table_name IS NOT NULL AND r.table_id IS NULL
  AND (m.clone_group_id IS NULL OR m.clone_group_id = m.id)
  AND m.table_created < DATEADD(day, -90, CURRENT_DATE())          -- older than the 90 days
  AND m.active_bytes + m.time_travel_bytes + m.failsafe_bytes >= POWER(1024, 3)   -- 1 GB or more
ORDER BY m.active_bytes DESC
LIMIT 50;
