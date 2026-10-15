-- query_id: sf_gov_data_egress
-- shims: DATA_TRANSFER_HISTORY, QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions DATA_TRANSFER_HISTORY, QUERY_HISTORY
-- fallback_note: data transfer for the last 14 days at most; queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
-- needs: MONITOR USAGE
WITH td AS (
  SELECT transfer_type, target_cloud, target_region, DATE(start_time) AS day,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_transferred, 0)) AS bytes_day,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_transferred, 0)) AS bytes_before,
         MIN(start_time) AS first_seen, MAX(start_time) AS last_seen
  -- BYTES_TRANSFERRED is a VARIANT, so it is cast before it is summed.
  FROM (SELECT start_time, source_cloud, source_region, target_cloud, target_region, transfer_type,
               TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred)) AS bytes_transferred
        FROM __SHIM_DATA_TRANSFER_HISTORY__)
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
  FROM __SHIM_QUERY_HISTORY__
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
