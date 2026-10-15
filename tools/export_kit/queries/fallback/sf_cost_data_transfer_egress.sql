-- query_id: sf_cost_data_transfer_egress
-- shims: DATA_TRANSFER_HISTORY
-- reads: INFORMATION_SCHEMA table functions DATA_TRANSFER_HISTORY
-- fallback_note: data transfer for the last 14 days at most
-- needs: MONITOR USAGE
WITH t AS (
  SELECT source_cloud, source_region, target_cloud, target_region, transfer_type,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_transferred, 0)) / POWER(1024, 4) AS cur_tb,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_transferred, 0)) / POWER(1024, 4) AS prev_tb
  -- BYTES_TRANSFERRED is a VARIANT, so it is cast before it is summed.
  FROM (SELECT start_time, source_cloud, source_region, target_cloud, target_region, transfer_type,
               TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred)) AS bytes_transferred
        FROM __SHIM_DATA_TRANSFER_HISTORY__)
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2, 3, 4, 5
),
s AS (
  SELECT t.*,
         COALESCE(UPPER(target_cloud) = UPPER(source_cloud), FALSE) AS same_cloud,
         IFF(COALESCE(UPPER(target_cloud) = UPPER(source_cloud), FALSE),
             :same_cloud_usd_per_tb, :other_cloud_usd_per_tb) AS usd_per_tb,
         100 * (cur_tb - prev_tb) / NULLIF(prev_tb, 0) AS change_pct
  FROM t
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, source_cloud, source_region,
       target_cloud, target_region, transfer_type,
       IFF(same_cloud, 'same_cloud_other_region', 'other_cloud_or_internet') AS route_kind,
       cur_tb AS current_tb, prev_tb AS previous_tb, change_pct, usd_per_tb,
       cur_tb * usd_per_tb AS est_egress_usd_list,
       prev_tb * usd_per_tb AS est_previous_egress_usd_list,
       'priced' AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN cur_tb * usd_per_tb >= :crit_usd THEN 'CRITICAL'
         WHEN cur_tb * usd_per_tb >= :warn_usd AND (prev_tb = 0 OR change_pct >= :warn_increase_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
WHERE cur_tb > 0 OR prev_tb > 0
ORDER BY est_egress_usd_list DESC
