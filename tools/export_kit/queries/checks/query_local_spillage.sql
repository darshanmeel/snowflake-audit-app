-- query_id: query_local_spillage
-- title: Queries spilling out of memory, per warehouse and day
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_spill_gb (default 1) GB a warehouse spills in a day (local + remote) that flags WARN;
--   :crit_spill_gb (default 10) the same for CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a day + warehouse whose queries spilled out of memory. The column that matters
--   is spilled_bytes_sum - bytes a sort, join or aggregation had to write to local SSD
--   (spilled_local_bytes_sum) or, worse, to remote storage (spilled_remote_bytes_sum) because it did not
--   fit in memory. executed_by is the user who spilled most that day. GB is 1024^3 bytes. Steady spill
--   on the same warehouse means under-provisioned memory or a skewed query, not a one-off.
-- healthy: spilled_bytes_sum below :warn_spill_gb GB/day per warehouse (field heuristic - tune
--   :warn_spill_gb for your account).
-- investigate_if: spilled_bytes_sum at/above :warn_spill_gb GB/day (WARN) or :crit_spill_gb
--   GB/day (CRITICAL) - field heuristic; sustained daily spill on the same warehouse is the real
--   signal.
-- actions: 1) cut what the query holds in memory - filter and select fewer columns earlier, avoid
--   exploding joins and large sorts or windows (free); 2) move the workload to a warehouse with more
--   memory, such as a Snowpark-optimized one (config); 3) size up the warehouse (spend).
-- next: none
-- caveats: spill = bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage (remote spill is the
--   costlier one; sf_query_remote_spill ranks it by statement shape). shuffle_read_bytes_sum =
--   bytes_sent_over_the_network.
WITH s AS (
  SELECT DATE(start_time) AS day, TO_VARCHAR(warehouse_id) AS warehouse_id, user_name,
         COALESCE(bytes_spilled_to_local_storage, 0) AS local_b,
         COALESCE(bytes_spilled_to_remote_storage, 0) AS remote_b,
         total_elapsed_time, execution_time, bytes_sent_over_the_network
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND COALESCE(bytes_spilled_to_local_storage, 0) + COALESCE(bytes_spilled_to_remote_storage, 0) > 0
),
u AS (
  SELECT day, warehouse_id, user_name, SUM(local_b + remote_b) AS b
  FROM s GROUP BY day, warehouse_id, user_name
),
g AS (
  -- one row per day and warehouse, so many users spilling a little still add up
  SELECT day, warehouse_id,
         COUNT(*) AS spilling_query_count,
         COUNT(DISTINCT user_name) AS spilling_users,
         SUM(local_b + remote_b) AS spilled_bytes_sum,
         SUM(local_b) AS spilled_local_bytes_sum,
         SUM(remote_b) AS spilled_remote_bytes_sum,
         MAX(local_b + remote_b) AS spilled_bytes_max,
         SUM(total_elapsed_time) AS total_duration_ms_sum,
         SUM(execution_time) AS execution_duration_ms_sum,
         SUM(bytes_sent_over_the_network) AS shuffle_read_bytes_sum
  FROM s
  GROUP BY day, warehouse_id
),
top_u AS (
  SELECT day, warehouse_id, MAX_BY(user_name, b) AS top_user
  FROM u GROUP BY day, warehouse_id
)
SELECT :period_days AS window_days, g.day, __ACCOUNT_ID__ AS account_id,
       IFF(g.warehouse_id IS NULL, 'CLOUD_SERVICES', 'WAREHOUSE') AS compute_type, g.warehouse_id,
       t.top_user AS executed_by, spilling_users, spilling_query_count,
       spilled_bytes_sum, spilled_local_bytes_sum, spilled_remote_bytes_sum, spilled_bytes_max,
       ROUND(spilled_bytes_sum / POWER(1024, 3), 2) AS spilled_gb,
       total_duration_ms_sum, execution_duration_ms_sum, shuffle_read_bytes_sum,
       CASE
         WHEN spilled_bytes_sum >= :crit_spill_gb * POWER(1024, 3) THEN 'CRITICAL'
         WHEN spilled_bytes_sum >= :warn_spill_gb * POWER(1024, 3) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
LEFT JOIN top_u t ON t.day = g.day AND t.warehouse_id IS NOT DISTINCT FROM g.warehouse_id
ORDER BY spilled_bytes_sum DESC
