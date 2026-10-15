-- query_id: sf_gov_data_egress
-- title: Data leaving the account: transfers and unloads
-- domain: governance_access   tier: standard
-- entity: destinations = row_kind, transfer_type, target_cloud, target_region, user_name, role_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_gb (default 10) gb: at or above this the row reads WARN; :crit_gb (default 500) gb: at
--   or above this the row reads CRITICAL; :baseline_days (default 90) baseline days: value this check
--   uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one day of one destination. row_kind TRANSFER = one transfer type (COPY,
--   REPLICATION, EXTERNAL_ACCESS ...) x target cloud and region, with gb_window = the GB billed as leaving
--   the region that day; new_destination is TRUE when nothing went there in the :baseline_days days
--   before. row_kind UNLOAD = one user x role x target of COPY INTO <location> statements that day, with
--   rows and outbound GB. dest_gb_window, gb_baseline, status and reasons judge the whole destination in
--   the window and repeat on each of its day rows; sum gb_window, never dest_gb_window.
-- healthy: status = OK for small, known flows (replication to your DR region, routine unloads
--   in-region).
-- investigate_if: WARN at :warn_gb+ GB, a new destination, or unloads that leave the cloud region;
--   CRITICAL at :warn_gb+ GB to a new destination, or :crit_gb+ GB that is at least twice the
--   destination's usual rate (its baseline scaled to the window): a steady known flow is WARN at most.
-- actions: 1) confirm each new destination and large unload with its owner (free); 2) set
--   PREVENT_UNLOAD_TO_INLINE_URL and require storage integrations so unloads only reach approved
--   buckets (config); 3) restrict external access integrations to named hosts (config)
-- next: none
-- caveats: in-region unloads to your own bucket are not billed as transfer, so they have no outbound
--   bytes; rows_unloaded still shows them. DATA_TRANSFER_HISTORY lags up to 2 hours; transfer bytes are
--   not tied to a user.
WITH td AS (
  SELECT transfer_type, target_cloud, target_region, DATE(start_time) AS day,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_transferred, 0)) AS bytes_day,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_transferred, 0)) AS bytes_before,
         MIN(start_time) AS first_seen, MAX(start_time) AS last_seen
  -- BYTES_TRANSFERRED is a VARIANT, so it is cast before it is summed.
  FROM (SELECT start_time, source_cloud, source_region, target_cloud, target_region, transfer_type,
               TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred)) AS bytes_transferred
        FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY)
  WHERE start_time >= DATEADD(day, -(:period_days + :baseline_days), __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2, 3, 4
),
-- Destination totals (window and baseline) repeat on each of its day rows; PARTITION BY keeps NULL clouds together.
t AS (
  SELECT td.*,
         SUM(bytes_day) OVER (PARTITION BY transfer_type, target_cloud, target_region) AS bytes_window,
         SUM(bytes_before) OVER (PARTITION BY transfer_type, target_cloud, target_region) AS bytes_baseline,
         MIN(first_seen) OVER (PARTITION BY transfer_type, target_cloud, target_region) AS dest_first_seen,
         MAX(last_seen) OVER (PARTITION BY transfer_type, target_cloud, target_region) AS dest_last_seen
  FROM td
),
und AS (
  SELECT user_name, role_name,
         COALESCE(outbound_data_transfer_cloud, 'same region') AS target_cloud,
         outbound_data_transfer_region AS target_region, DATE(start_time) AS day,
         COUNT(*) AS statements,
         SUM(COALESCE(rows_produced, 0)) AS rows_unloaded,
         SUM(COALESCE(outbound_data_transfer_bytes, 0)) AS bytes_day,
         MIN(start_time) AS first_seen, MAX(start_time) AS last_seen
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type = 'UNLOAD' AND execution_status = 'SUCCESS'
  GROUP BY 1, 2, 3, 4, 5
),
un AS (
  SELECT und.*,
         SUM(bytes_day) OVER (PARTITION BY user_name, role_name, target_cloud, target_region) AS bytes_window,
         SUM(statements) OVER (PARTITION BY user_name, role_name, target_cloud, target_region) AS dest_statements,
         SUM(rows_unloaded) OVER (PARTITION BY user_name, role_name, target_cloud, target_region) AS dest_rows_unloaded,
         MIN(first_seen) OVER (PARTITION BY user_name, role_name, target_cloud, target_region) AS dest_first_seen,
         MAX(last_seen) OVER (PARTITION BY user_name, role_name, target_cloud, target_region) AS dest_last_seen
  FROM und
),
rows_ AS (
  SELECT 'TRANSFER' AS row_kind, day, CAST(NULL AS VARCHAR) AS user_name, CAST(NULL AS VARCHAR) AS role_name,
         transfer_type, target_cloud, target_region, CAST(NULL AS NUMBER) AS statements,
         CAST(NULL AS NUMBER) AS rows_unloaded, bytes_day / POWER(1024, 3) AS gb_window,
         bytes_window / POWER(1024, 3) AS dest_gb_window,
         bytes_baseline / POWER(1024, 3) AS gb_baseline, bytes_baseline = 0 AS new_destination,
         dest_first_seen AS first_seen, dest_last_seen AS last_seen,
         CAST(NULL AS NUMBER) AS dest_statements, CAST(NULL AS NUMBER) AS dest_rows_unloaded
  FROM t
  WHERE bytes_day > 0
  UNION ALL
  SELECT 'UNLOAD', day, user_name, role_name, 'UNLOAD', target_cloud, target_region, statements, rows_unloaded,
         bytes_day / POWER(1024, 3), bytes_window / POWER(1024, 3), NULL, FALSE, dest_first_seen, dest_last_seen,
         dest_statements, dest_rows_unloaded
  FROM un
)
-- status and reasons judge the whole destination (dest_gb_window) and repeat on each of its day rows.
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind, day, user_name, role_name, transfer_type,
       target_cloud, target_region, statements, rows_unloaded, gb_window, dest_gb_window, gb_baseline, new_destination,
       first_seen, last_seen,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         ROUND(dest_gb_window, 2) || ' GB to ' || target_cloud || COALESCE(' ' || target_region, '') || ' in the window',
         IFF(new_destination, 'new destination', NULL),
         IFF(row_kind = 'UNLOAD', dest_statements || ' unloads, ' || dest_rows_unloaded || ' rows', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         -- a known flow at its usual size (replication to DR) is not an incident: only a jump or a new place is
         WHEN (new_destination AND dest_gb_window >= :warn_gb)
              OR (dest_gb_window >= :crit_gb
                  AND dest_gb_window >= 2 * COALESCE(gb_baseline, 0) * :period_days / :baseline_days) THEN 'CRITICAL'
         WHEN dest_gb_window >= :warn_gb OR new_destination
              OR (row_kind = 'UNLOAD' AND target_cloud <> 'same region') THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM rows_
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, dest_gb_window DESC, day
