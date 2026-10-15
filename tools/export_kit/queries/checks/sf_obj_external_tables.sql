-- query_id: sf_obj_external_tables
-- title: External tables: broken, stale or refreshed for nobody
-- domain: storage   tier: standard
-- windowed: yes
-- pre: SHOW EXTERNAL TABLES IN ACCOUNT
-- reads: SHOW EXTERNAL TABLES IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :stale_days (default 7) stale days: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one external table. auto_refresh = a cloud notification channel feeds it, so
--   Snowflake registers new files serverlessly. last_refreshed_on is the last metadata refresh; read_queries counts queries that read it
--   (ACCESS_HISTORY). An external table no one reads still bills its auto-refresh, but Snowflake
--   does not bill that per table, so there is no $ here.
-- healthy: status = OK when the table is valid, is read, and (if auto-refreshed) refreshed recently.
-- investigate_if: WARN when nobody read it in the window or an auto-refreshed table has not refreshed
--   in stale_days; CRITICAL when the table is invalid (stage or integration gone).
-- actions: 1) drop unread external tables, or ALTER EXTERNAL TABLE ... SET AUTO_REFRESH = FALSE (free);
--   2) fix the stage, storage integration or event notification of invalid / stale tables (config); 3)
--   for hot data, load it into a native table or an Iceberg table instead (engineering).
-- next: none
-- caveats: refresh credits are not shown: AUTO_REFRESH_REGISTRATION_HISTORY is not an ACCOUNT_USAGE view,
--   and PIPE_USAGE_HISTORY rows for auto-refresh have NULL pipe names, so they cannot be tied to a
--   table. ACCESS_HISTORY needs Enterprise Edition; with no rows reads are not judged. SHOW lists
--   what the export role can see.
WITH x AS (
  SELECT "database_name" AS database_name, "schema_name" AS schema_name, "name" AS table_name,
         "database_name" || '.' || "schema_name" || '.' || "name" AS table_fqn,
         "owner" AS table_owner, "stage" AS stage, "location" AS location,
         COALESCE("file_format_type", "file_format_name") AS file_format, "table_format" AS table_format,
         NULLIF(TRIM("notification_channel"), '') AS notification_channel,
         LOWER(TO_VARCHAR("invalid")) = 'true' AS is_invalid,
         NULLIF(TRIM("invalid_reason"), '') AS invalid_reason,
         CAST("last_refreshed_on" AS TIMESTAMP_LTZ) AS last_refreshed_on,
         CAST("created_on" AS TIMESTAMP_LTZ) AS created_on
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
ah AS (
  SELECT ah.query_id, ah.query_start_time, UPPER(f.value:objectName::STRING) AS name_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.base_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
reads AS (
  SELECT name_key, COUNT(DISTINCT query_id) AS read_queries, MAX(query_start_time) AS last_read_at
  FROM ah GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM ah
),
j AS (
  SELECT x.*, x.notification_channel IS NOT NULL AS auto_refresh,
         COALESCE(r.read_queries, 0) AS read_queries, r.last_read_at, seen.access_rows,
         (seen.access_rows > 0 AND r.name_key IS NULL
          AND x.created_on < DATEADD(day, -:period_days, __AS_OF_DATE__)) AS unread
  FROM x
  LEFT JOIN reads r ON r.name_key = UPPER(x.table_fqn)
  CROSS JOIN seen
),
scored AS (
  SELECT j.*,
         (auto_refresh AND COALESCE(last_refreshed_on, created_on) < DATEADD(day, -:stale_days, LEAST(CURRENT_TIMESTAMP(), CAST(__AS_OF_DATE__ AS TIMESTAMP))))
           AS refresh_stale
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_name, database_name, schema_name, table_owner, stage, location, file_format,
       table_format, auto_refresh, notification_channel, is_invalid, invalid_reason, created_on,
       last_refreshed_on, read_queries, last_read_at,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(is_invalid, 'invalid: ' || COALESCE(invalid_reason, 'see SHOW EXTERNAL TABLES'), NULL),
         IFF(unread, 'not read in ' || :period_days || ' days', NULL),
         IFF(refresh_stale, 'auto-refresh has not run in ' || :stale_days || ' days', NULL)), '; ') AS reasons,
       CASE WHEN access_rows = 0 THEN 'no_access_history' END AS not_assessed_reason,
       CASE
         WHEN is_invalid THEN 'CRITICAL'
         WHEN unread OR refresh_stale THEN 'WARN'
         WHEN access_rows = 0 THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, table_fqn
