-- query_id: sf_ai_spcs_costs_outside_pools
-- title: Container storage and transfer outside pool credits
-- domain: serving_ai   tier: standard
-- entity: compute pools = compute_pool_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.BLOCK_STORAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.INTERNAL_DATA_TRANSFER_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Snowpark Container Services available in the region
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_growth_pct (default 25) percent: snapshot storage growing this much over the window before
--   flags; :min_gb (default 10) gb: least snapshot storage before growth flags
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. BLOCK_STORAGE_HISTORY and INTERNAL_DATA_TRANSFER_HISTORY
--   document no retention.
-- read_this: one row = one compute pool (a dropped pool keeps its rows), plus one snapshots row, which belongs
--   to no pool. pool_credits are the credits the pool used in the window (priced on the compute pool page).
--   The storage and transfer columns are GB only: Snowflake publishes no per-GB rate for block storage, IOPS or
--   internal transfer in any view, so there is no $ here, and none is claimed.
-- healthy: status = OK when a pool that keeps block storage also used credits and snapshot storage is flat.
-- investigate_if: WARN when a pool holds block storage but used no credits in the window (volumes kept for
--   a stopped or dropped pool), or when snapshot storage grew :warn_growth_pct percent over the window before
--   (and holds :min_gb GB or more).
-- actions: 1) drop the volumes and snapshots of a pool that is no longer used (free); 2) lower the volume
--   IOPS and throughput that was added on top of the defaults (config)
-- next: sf_ai_spcs_pool_no_live_service, sf_ai_compute_pools_config, sf_ai_snowpark_container_services
-- caveats: Block storage, additional IOPS and throughput, and internal transfer are billed at rates no view
--   exposes, so this check shows quantities only. Pools are matched on COMPUTE_POOL_ID; internal transfer has
--   no pool id, so it is matched by name and goes to the newest pool of that name. Snapshot rows carry no pool.
--   Days with no storage row count as zero. Services that never suspend are on the pool idle check.
--   ACCOUNT_USAGE lags up to 3 hours.
WITH cr AS (
  SELECT compute_pool_id, MAX(compute_pool_name) AS pool_name, SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY compute_pool_id
),
blk AS (
  SELECT compute_pool_id, MAX(compute_pool_name) AS pool_name,
         SUM(bytes) / :period_days / POWER(1024, 3) AS block_gb_avg,
         SUM(additional_iops) / :period_days AS iops_avg,
         SUM(additional_throughput) / :period_days AS throughput_avg
  FROM SNOWFLAKE.ACCOUNT_USAGE.BLOCK_STORAGE_HISTORY
  WHERE UPPER(storage_type) = 'BLOCK_STORAGE'
    AND usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY compute_pool_id
),
ids AS (
  SELECT compute_pool_id, MAX(pool_name) AS pool_name
  FROM (SELECT compute_pool_id, pool_name FROM cr UNION ALL SELECT compute_pool_id, pool_name FROM blk)
  GROUP BY compute_pool_id
),
by_name AS (
  SELECT UPPER(pool_name) AS name_key, MAX(compute_pool_id) AS compute_pool_id FROM ids GROUP BY 1
),
xf AS (
  SELECT bn.compute_pool_id, UPPER(COALESCE(x.compute_pool_name, '')) AS name_key,
         MAX(x.compute_pool_name) AS pool_name,
         SUM(IFF(UPPER(x.transfer_type) = 'SERVICE_FUNCTION', x.bytes_transferred, 0)) / POWER(1024, 3) AS svc_fn_gb,
         SUM(IFF(UPPER(x.transfer_type) = 'COMPUTE_POOL', x.bytes_transferred, 0)) / POWER(1024, 3) AS pool_gb
  FROM SNOWFLAKE.ACCOUNT_USAGE.INTERNAL_DATA_TRANSFER_HISTORY x
  LEFT JOIN by_name bn ON bn.name_key = UPPER(COALESCE(x.compute_pool_name, ''))
  WHERE x.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND x.start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
snap AS (
  SELECT SUM(IFF(usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__), bytes, 0)) / :period_days / POWER(1024, 3) AS cur_gb,
         SUM(IFF(usage_date < DATEADD(day, -:period_days, __AS_OF_DATE__), bytes, 0)) / :period_days / POWER(1024, 3) AS prev_gb
  FROM SNOWFLAKE.ACCOUNT_USAGE.BLOCK_STORAGE_HISTORY
  WHERE UPPER(storage_type) = 'SNAPSHOT'
    AND usage_date >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
k AS (
  SELECT compute_pool_id, CAST(NULL AS VARCHAR) AS name_key, pool_name FROM ids
  UNION ALL
  SELECT CAST(NULL AS NUMBER), name_key, pool_name FROM xf WHERE compute_pool_id IS NULL
),
p AS (
  SELECT 'pool' AS row_kind, k.pool_name AS compute_pool_name, k.compute_pool_id,
         COALESCE(cr.credits, 0) AS pool_credits,
         COALESCE(blk.block_gb_avg, 0) AS block_gb, blk.iops_avg, blk.throughput_avg,
         CAST(NULL AS DOUBLE) AS snapshot_gb, CAST(NULL AS DOUBLE) AS prev_snapshot_gb,
         COALESCE(xf.svc_fn_gb, 0) AS svc_fn_gb, COALESCE(xf.pool_gb, 0) AS pool_gb
  FROM k
  LEFT JOIN cr ON cr.compute_pool_id = k.compute_pool_id
  LEFT JOIN blk ON blk.compute_pool_id = k.compute_pool_id
  LEFT JOIN xf ON (k.compute_pool_id IS NOT NULL AND xf.compute_pool_id = k.compute_pool_id)
              OR (k.compute_pool_id IS NULL AND xf.compute_pool_id IS NULL AND xf.name_key = k.name_key)
  UNION ALL
  SELECT 'snapshots', CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER), CAST(NULL AS DOUBLE),
         CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         COALESCE(cur_gb, 0), COALESCE(prev_gb, 0), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE)
  FROM snap
  WHERE COALESCE(cur_gb, 0) > 0 OR COALESCE(prev_gb, 0) > 0
),
s AS (
  SELECT p.*,
         row_kind = 'pool' AND block_gb > 0 AND pool_credits = 0 AS stopped_pool_storage,
         row_kind = 'snapshots' AND prev_snapshot_gb >= :min_gb
           AND 100 * (snapshot_gb - prev_snapshot_gb) / NULLIF(prev_snapshot_gb, 0) >= :warn_growth_pct AS snapshot_growth
  FROM p
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind, compute_pool_name, compute_pool_id,
       IFF(row_kind = 'snapshots', '(snapshots)', IFF(compute_pool_name IS NULL, '(no pool named)', NULL)) AS row_label,
       pool_credits,
       block_gb AS block_storage_gb_avg, snapshot_gb AS snapshot_gb_avg, prev_snapshot_gb AS previous_snapshot_gb_avg,
       iops_avg AS additional_iops_avg, throughput_avg AS additional_throughput_avg,
       svc_fn_gb AS internal_transfer_service_function_gb, pool_gb AS internal_transfer_compute_pool_gb,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(stopped_pool_storage, 'holds ' || ROUND(block_gb, 1) || ' GB of block storage but used no credits', NULL),
         IFF(snapshot_growth, 'snapshot storage grew from ' || ROUND(prev_snapshot_gb, 1) || ' to '
             || ROUND(snapshot_gb, 1) || ' GB', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(stopped_pool_storage OR snapshot_growth, 'WARN', 'OK') AS status
FROM s
ORDER BY IFF(stopped_pool_storage OR snapshot_growth, 0, 1), block_gb DESC NULLS LAST, compute_pool_name
