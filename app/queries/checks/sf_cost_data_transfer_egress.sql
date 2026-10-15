-- query_id: sf_cost_data_transfer_egress
-- title: Data transfer egress by destination
-- domain: cost   tier: standard
-- money: est_egress_usd_list
-- entity: transfer routes = source_cloud, source_region, target_cloud, target_region, transfer_type
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :same_cloud_usd_per_tb (default 20) same cloud usd per tb: value this check uses;
--   :other_cloud_usd_per_tb (default 90) other cloud usd per tb: value this check uses; :warn_usd
--   (default 50) usd: at or above this the row reads WARN; :crit_usd (default 500) usd: at or above
--   this the row reads CRITICAL; :warn_increase_pct (default 50) increase pct: at or above this the row
--   reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one source region -> target cloud/region x transfer type (COPY, unload,
--   replication, external function, ...). Snowflake's usage views carry no transfer price, so
--   est_egress_usd_list = TB x same_cloud_usd_per_tb (another region of the same cloud) or
--   other_cloud_usd_per_tb (another cloud or the internet); set them to your rate card.
-- healthy: status = OK when egress is small or flat.
-- investigate_if: WARN when a route costs >= warn_usd and is new or grew >= warn_increase_pct; CRITICAL
--   when a route costs >= crit_usd.
-- actions: 1) find the job behind the route (unloads to another cloud's bucket, replication to a far
--   region, external functions) (free); 2) keep stages and consumers in the same region and cloud,
--   compress unloads, replicate less often (config); 3) move the consumer next to the data or share it
--   with Secure Data Sharing instead of copying (spend).
-- next: none
-- caveats: the per-TB rates are parameters, not your invoice; sf_cost_invoice_vs_metered shows the
--   billed transfer amount when ORGANIZATION_USAGE is readable. Same-region transfer is free and not
--   listed.
WITH t AS (
  SELECT source_cloud, source_region, target_cloud, target_region, transfer_type,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_transferred, 0)) / POWER(1024, 4) AS cur_tb,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), bytes_transferred, 0)) / POWER(1024, 4) AS prev_tb
  -- BYTES_TRANSFERRED is a VARIANT, so it is cast before it is summed.
  FROM (SELECT start_time, source_cloud, source_region, target_cloud, target_region, transfer_type,
               TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred)) AS bytes_transferred
        FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY)
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
