-- query_id: sf_wh_load_utilization
-- title: Warehouse load per billed hour (running, queued, blocked)
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_credits (default 20) credits: least a row needs before it can flag; :warn_low_load
--   (default 0.5) low load: at or above this the row reads WARN; :crit_low_load (default 0.2) low load:
--   at or above this the row reads CRITICAL; :crit_min_credits (default 200) min credits: at or above
--   this the row reads CRITICAL; :low_hour_load (default 0.25) low hour load: value this check uses;
--   :warn_queued_pct (default 10) queued pct: at or above this the row reads WARN
-- not_assessed_reasons: not_in_show: the warehouse billed compute but SHOW WAREHOUSES does not list it
--   (dropped, or the role cannot see it), so its rate is unknown; unknown_size: no fixed hourly rate
--   (adaptive); below_min_credits: under min_credits in the window; no_load_history: WAREHOUSE_LOAD_HISTORY
--   has no rows for the warehouse in the window, so its load is unknown, not zero
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. avg_load_per_billed_hour = average number of queries running per
--   billed cluster-hour (1.0 = one query running the whole time). low_load_hours = billed hours whose
--   running load per billed cluster-hour stayed under low_hour_load. queued_pct / provisioning_pct /
--   blocked_pct = those loads as a share of all load. peak_hour_load = busiest hour, per billed
--   cluster-hour.
-- healthy: status = OK when the warehouse runs at least warn_low_load queries per billed hour and
--   rarely queues
-- investigate_if: WARN when avg_load_per_billed_hour < warn_low_load (and credits >= min_credits) or
--   queued_pct >= warn_queued_pct; CRITICAL when < crit_low_load and credits >= crit_min_credits
-- actions: 1) low load, merge the workload onto a busier warehouse of the same size, see
--   sf_wh_consolidation_candidates (config); 2) low load with short queries, size down, see
--   sf_wh_oversized (config); 3) queued, add clusters or split workloads; blocked, see
--   sf_query_blocked_lock_waits (config)
-- next: none
-- caveats: load counts queries, not CPU; one heavy query at load 1.0 can still use the whole warehouse.
--   Billed hours = compute credits / the current size's rate for its generation.
WITH __INCLUDE_warehouse_config__,
ld AS (
  SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_start,
         SUM(avg_running * DATEDIFF(second, start_time, end_time)) / 3600 AS running_load,
         SUM(avg_queued_load * DATEDIFF(second, start_time, end_time)) / 3600 AS queued_load,
         SUM(avg_queued_provisioning * DATEDIFF(second, start_time, end_time)) / 3600 AS provisioning_load,
         SUM(avg_blocked * DATEDIFF(second, start_time, end_time)) / 3600 AS blocked_load
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
m AS (
  SELECT warehouse_name, warehouse_id, start_time AS hour_start, credits_used_compute AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND credits_used_compute > 0
),
hr AS (
  SELECT m.warehouse_name, m.warehouse_id, m.hour_start, m.credits, l.warehouse_name IS NOT NULL AS has_load,
         -- per billed cluster-hour, as avg_load_per_billed_hour, so a short busy run is not a low-load hour
         COALESCE(l.running_load, 0) / NULLIF(m.credits / NULLIF(c.credits_per_hour, 0), 0) AS load_per_billed_hour,
         COALESCE(l.running_load, 0) AS running_load, COALESCE(l.queued_load, 0) AS queued_load,
         COALESCE(l.provisioning_load, 0) AS provisioning_load, COALESCE(l.blocked_load, 0) AS blocked_load
  FROM m LEFT JOIN ld l ON l.warehouse_name = m.warehouse_name AND l.hour_start = m.hour_start
  LEFT JOIN warehouse_config c ON c.warehouse_name = m.warehouse_name
),
w AS (
  SELECT warehouse_name, MAX(warehouse_id) AS metered_warehouse_id, COUNT(*) AS billed_hours,
         SUM(credits) AS compute_credits, COUNT_IF(has_load) AS load_hours,
         SUM(running_load) AS running_query_hours, SUM(queued_load) AS queued_query_hours,
         SUM(provisioning_load) AS provisioning_query_hours, SUM(blocked_load) AS blocked_query_hours,
         COUNT_IF(load_per_billed_hour < :low_hour_load) AS low_load_hours,
         SUM(IFF(load_per_billed_hour < :low_hour_load, credits, 0)) AS low_load_credits,
         MAX(load_per_billed_hour) AS peak_hour_load
  FROM hr
  GROUP BY 1
),
j AS (
  SELECT COALESCE(c.warehouse_id, TO_VARCHAR(w.metered_warehouse_id)) AS warehouse_id, w.warehouse_name,
         c.warehouse_name IS NOT NULL AS in_show, w.load_hours, c.warehouse_size, CAST(c.max_clusters AS INTEGER) AS max_clusters,
         c.credits_per_hour, w.billed_hours, w.compute_credits, w.running_query_hours, w.queued_query_hours,
         w.provisioning_query_hours, w.blocked_query_hours,
         -- no load rows or no rate means load per billed hour is unknown, so it stays empty rather than 0
         IFF(w.load_hours = 0 OR c.credits_per_hour IS NULL, NULL, w.low_load_hours) AS low_load_hours,
         IFF(w.load_hours = 0 OR c.credits_per_hour IS NULL, NULL, w.low_load_credits) AS low_load_credits,
         IFF(w.load_hours = 0, NULL, w.peak_hour_load) AS peak_hour_load,
         -- per billed cluster-hour, so a multi-cluster warehouse is judged per running cluster
         IFF(w.load_hours = 0, NULL,
             w.running_query_hours / NULLIF(w.compute_credits / NULLIF(c.credits_per_hour, 0), 0)) AS avg_load_per_billed_hour,
         w.running_query_hours + w.queued_query_hours + w.provisioning_query_hours + w.blocked_query_hours AS all_load
  FROM w LEFT JOIN warehouse_config c ON c.warehouse_name = w.warehouse_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, max_clusters, billed_hours, compute_credits,
       compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list,
       avg_load_per_billed_hour, peak_hour_load, low_load_hours, low_load_credits,
       low_load_credits * __CREDIT_PRICE__ AS est_low_load_usd_list,
       100 * queued_query_hours / NULLIF(all_load, 0) AS queued_pct,
       100 * provisioning_query_hours / NULLIF(all_load, 0) AS provisioning_pct,
       100 * blocked_query_hours / NULLIF(all_load, 0) AS blocked_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN NOT in_show THEN 'not_in_show'
            WHEN credits_per_hour IS NULL THEN 'unknown_size'
            WHEN compute_credits < :min_credits THEN 'below_min_credits'
            WHEN load_hours = 0 THEN 'no_load_history' END AS not_assessed_reason,
       CASE
         WHEN credits_per_hour IS NULL OR compute_credits < :min_credits OR load_hours = 0 THEN 'NOT_ASSESSED'
         WHEN avg_load_per_billed_hour < :crit_low_load AND compute_credits >= :crit_min_credits THEN 'CRITICAL'
         WHEN avg_load_per_billed_hour < :warn_low_load
           OR 100 * queued_query_hours / NULLIF(all_load, 0) >= :warn_queued_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY low_load_credits DESC NULLS LAST, warehouse_name
