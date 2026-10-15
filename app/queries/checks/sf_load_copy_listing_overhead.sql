-- query_id: sf_load_copy_listing_overhead
-- title: COPY loads that spend their time listing stage files
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- entity: warehouses = warehouse_id
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_list_pct (default 25) percent of the COPY time spent listing files at or above which the
--   row reads WARN; :crit_list_pct (default 50) the same that reads CRITICAL; :min_list_minutes (default
--   10) minutes of listing in the window a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse and user whose COPY statements listed external stage files in the
--   window. copy_shapes counts their distinct statement shapes (query_parameterized_hash, never the
--   text). list_minutes is the summed LIST_EXTERNAL_FILES_TIME; list_pct is its share of the statements'
--   total elapsed time. A COPY lists every file under the path it names, loaded or not, so a wide prefix
--   gets slower as files pile up.
--   cloud_services_credits are the statements' cloud services credits before the daily 10% adjustment:
--   listing runs in the cloud services layer, so it shows there and is billed only above the
--   allowance (sf_cost_cloud_services_billed). No $ here: how much of it is billed is not known per
--   statement.
-- healthy: status = OK when listing takes under warn_list_pct of the COPY time, or under
--   min_list_minutes in the window.
-- investigate_if: WARN when list_pct >= warn_list_pct and list_minutes >= min_list_minutes; CRITICAL when
--   list_pct >= crit_list_pct.
-- actions: 1) name a narrower path in the COPY (a date prefix such as @stage/2026/10/05/) instead of a
--   PATTERN over the whole stage (free); 2) move or delete loaded files out of the prefix (free); 3)
--   load new files with Snowpipe AUTO_INGEST or a directory table, which need no listing (config)
-- next: sf_load_small_files, sf_cost_cloud_services_billed, sf_load_bulk_copy_vs_snowpipe
-- caveats: heavy: reads QUERY_HISTORY for the window (period_days only), COPY statements only; only
--   aggregates leave Snowflake. Internal stages report no listing time here. QUERY_HISTORY lags up to 45
--   minutes.
WITH cp AS (
  SELECT warehouse_id, warehouse_name, user_name, COALESCE(query_parameterized_hash, query_hash) AS shape,
         list_external_files_time, total_elapsed_time, execution_time, credits_used_cloud_services
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type = 'COPY' AND COALESCE(list_external_files_time, 0) > 0
),
g AS (
  SELECT MAX(TO_VARCHAR(warehouse_id)) AS warehouse_id, warehouse_name, user_name, COUNT(DISTINCT shape) AS copy_shapes,
         COUNT(*) AS copies,
         SUM(list_external_files_time) / 60000 AS list_minutes,
         MEDIAN(list_external_files_time) / 1000 AS median_list_s,
         SUM(total_elapsed_time) / 60000 AS elapsed_minutes,
         SUM(execution_time) / 60000 AS exec_minutes,
         SUM(credits_used_cloud_services) AS cloud_services_credits
  FROM cp
  GROUP BY 2, 3
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, COALESCE(warehouse_id, warehouse_name) AS warehouse_id,
       warehouse_name, user_name, copy_shapes, copies,
       ROUND(list_minutes, 1) AS list_minutes, ROUND(median_list_s, 1) AS median_list_s,
       ROUND(elapsed_minutes, 1) AS elapsed_minutes, ROUND(exec_minutes, 1) AS exec_minutes,
       ROUND(100 * list_minutes / NULLIF(elapsed_minutes, 0), 1) AS list_pct,
       cloud_services_credits,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN list_minutes < :min_list_minutes THEN 'OK'
         WHEN 100 * list_minutes / NULLIF(elapsed_minutes, 0) >= :crit_list_pct THEN 'CRITICAL'
         WHEN 100 * list_minutes / NULLIF(elapsed_minutes, 0) >= :warn_list_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY list_minutes DESC, warehouse_name
