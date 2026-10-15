-- query_id: sf_wh_resume_churn
-- title: Warehouse runs shorter than the 60-second billing minimum
-- domain: compute   tier: standard
-- windowed: yes
-- money: est_idle_context_usd_list
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_short_runs (default 20) runs under 60 s a warehouse needs before it can flag;
--   :warn_short_pct (default 25) percent of its runs under 60 s at or above which the row reads WARN;
--   :crit_credits (default 50) credits billed for the minimum at or above which a WARN row reads
--   CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. A run is a resume to the next suspend in WAREHOUSE_EVENTS_HISTORY:
--   the warehouse's own RESUME_WAREHOUSE and SUSPEND_WAREHOUSE events, and RESUME_CLUSTER and
--   SUSPEND_CLUSTER for clusters 2 and up. Each run bills at least 60 s, so a run of 15 s bills 45 s for
--   nothing. short_runs counts runs under 60 s; minimum_billed_min adds up those top-ups. by_manual,
--   by_auto, by_monitor and by_cluster split the short runs by what ended them: an ALTER WAREHOUSE ...
--   SUSPEND, the auto-suspend, a resource monitor, or an extra cluster stopping. top_suspend_user_name is the
--   user whose suspends ended the most short runs. minimum_credits prices the top-ups at the
--   warehouse's credits per hour (the same rate as sf_wh_auto_suspend_tuning) and is capped at its idle
--   credits. est_idle_context_usd_list is part of the idle $ of sf_wh_idle_minutes, never added to it
--   or to any waste total.
-- healthy: status = OK when fewer than min_short_runs runs, or under warn_short_pct percent of runs,
--   end before 60 s
-- investigate_if: WARN when short_runs >= min_short_runs and short_run_pct >= warn_short_pct;
--   CRITICAL when minimum_credits is also >= crit_credits
-- actions: 1) stop suspending the warehouse from scripts after each job: let auto-suspend do it, so
--   back-to-back jobs share one run (free); 2) set AUTO_SUSPEND to 60 s or more (config); 3) batch small
--   jobs into one run, or move them to serverless tasks billed per second with no minimum (config)
-- next: sf_wh_auto_suspend_tuning, sf_wh_idle_minutes
-- not_assessed_reasons: unknown_size: the warehouse's size or type has no fixed hourly rate (adaptive),
--   so the minimum cannot be priced
-- caveats: a run starts at its resume event and ends at the next suspend event; one that is still
--   running at the end of the window, or began before it, is left out. Events lag up to 3 h. A
--   setting of 60 s or more already keeps every run at least 60 s, so short runs come from manual
--   suspends, resource monitors, a setting under 60 s, or extra clusters. Each extra cluster bills its
--   own minimum at the same rate.
WITH __INCLUDE_warehouse_config__,
ev AS (
  -- level 0 = the warehouse, n = extra cluster n; one action can write a STARTED and a COMPLETED row
  SELECT warehouse_name, timestamp, event_reason, user_name,
         IFF(event_name IN ('RESUME_WAREHOUSE', 'SUSPEND_WAREHOUSE'), 0, cluster_number) AS lvl,
         IFF(event_name LIKE 'RESUME_%', 'R', 'S') AS kind,
         IFF(COALESCE(event_state, 'COMPLETED') = 'STARTED', 0, 1) AS state_order
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
    AND (event_name IN ('RESUME_WAREHOUSE', 'SUSPEND_WAREHOUSE')
         OR (event_name IN ('RESUME_CLUSTER', 'SUSPEND_CLUSTER') AND cluster_number > 1))
),
seq AS (
  SELECT ev.*, LAG(kind) OVER (PARTITION BY warehouse_name, lvl ORDER BY timestamp, state_order) AS prev_kind
  FROM ev
),
edges AS (
  -- the first row of each resume or suspend: a repeat of the same kind is the same action
  SELECT warehouse_name, lvl, kind, timestamp, event_reason, user_name,
         LEAD(kind) OVER (PARTITION BY warehouse_name, lvl ORDER BY timestamp) AS next_kind,
         LEAD(timestamp) OVER (PARTITION BY warehouse_name, lvl ORDER BY timestamp) AS next_ts,
         LEAD(event_reason) OVER (PARTITION BY warehouse_name, lvl ORDER BY timestamp) AS next_reason,
         LEAD(user_name) OVER (PARTITION BY warehouse_name, lvl ORDER BY timestamp) AS next_user
  FROM seq
  WHERE prev_kind IS NULL OR prev_kind <> kind
),
runs AS (
  SELECT warehouse_name, lvl, DATEDIFF(millisecond, timestamp, next_ts) / 1000 AS run_s,
         next_reason AS end_reason, next_user AS end_user
  FROM edges
  WHERE kind = 'R' AND next_kind = 'S'
),
rs AS (
  SELECT warehouse_name, COUNT(*) AS runs, COUNT_IF(run_s < 60) AS short_runs,
         MEDIAN(IFF(run_s < 60, run_s, NULL)) AS median_short_run_s,
         SUM(IFF(run_s < 60, 60 - run_s, 0)) AS minimum_billed_s,
         COUNT_IF(run_s < 60 AND lvl = 0 AND end_reason = 'WAREHOUSE_SUSPEND') AS by_manual,
         COUNT_IF(run_s < 60 AND lvl = 0 AND end_reason = 'WAREHOUSE_AUTOSUSPEND') AS by_auto,
         COUNT_IF(run_s < 60 AND lvl = 0 AND end_reason = 'RESOURCE_MONITOR_SUSPEND') AS by_monitor,
         COUNT_IF(run_s < 60 AND lvl > 0) AS by_cluster
  FROM runs
  GROUP BY 1
),
who AS (
  SELECT warehouse_name, end_user AS top_suspend_user_name, COUNT(*) AS top_suspend_user_runs
  FROM runs
  WHERE run_s < 60 AND lvl = 0 AND end_reason = 'WAREHOUSE_SUSPEND' AND end_user IS NOT NULL
  GROUP BY 1, 2
  QUALIFY ROW_NUMBER() OVER (PARTITION BY warehouse_name ORDER BY COUNT(*) DESC, end_user) = 1
),
m AS (
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits,
         SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
r AS (
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_size, c.warehouse_type, c.credits_per_hour,
         CAST(c.max_clusters AS INTEGER) AS max_clusters, CAST(c.auto_stop_minutes * 60 AS INTEGER) AS auto_suspend_s,
         COALESCE(rs.runs, 0) AS runs, COALESCE(rs.short_runs, 0) AS short_runs, rs.median_short_run_s,
         COALESCE(rs.minimum_billed_s, 0) AS minimum_billed_s, COALESCE(rs.by_manual, 0) AS by_manual,
         COALESCE(rs.by_auto, 0) AS by_auto, COALESCE(rs.by_monitor, 0) AS by_monitor,
         COALESCE(rs.by_cluster, 0) AS by_cluster, who.top_suspend_user_name, who.top_suspend_user_runs,
         m.compute_credits, m.idle_credits
  FROM warehouse_config c
  LEFT JOIN rs ON rs.warehouse_name = c.warehouse_name
  LEFT JOIN who ON who.warehouse_name = c.warehouse_name
  LEFT JOIN m ON m.warehouse_name = c.warehouse_name
),
f AS (
  -- billed with no query running, so part of the idle credits and never more than them
  SELECT r.*,
         LEAST(minimum_billed_s / 3600 * credits_per_hour,
               IFF(idle_credits IS NULL, minimum_billed_s / 3600 * credits_per_hour, GREATEST(idle_credits, 0))) AS minimum_credits
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, warehouse_size,
       COALESCE(warehouse_type, 'STANDARD') AS warehouse_type, max_clusters, credits_per_hour, auto_suspend_s,
       runs, short_runs, ROUND(100 * short_runs / NULLIF(runs, 0), 1) AS short_run_pct,
       ROUND(short_runs / :period_days, 1) AS short_runs_per_day, ROUND(median_short_run_s, 1) AS median_short_run_s,
       ROUND(minimum_billed_s / 60, 1) AS minimum_billed_min, by_manual, by_auto, by_monitor, by_cluster,
       top_suspend_user_name, top_suspend_user_runs, idle_credits, minimum_credits,
       minimum_credits * __CREDIT_PRICE__ AS est_idle_context_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(credits_per_hour IS NULL, 'unknown_size', NULL) AS not_assessed_reason,
       CASE
         WHEN credits_per_hour IS NULL THEN 'NOT_ASSESSED'
         WHEN short_runs >= :min_short_runs AND 100 * short_runs / NULLIF(runs, 0) >= :warn_short_pct
              AND minimum_credits >= :crit_credits THEN 'CRITICAL'
         WHEN short_runs >= :min_short_runs AND 100 * short_runs / NULLIF(runs, 0) >= :warn_short_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY minimum_credits DESC NULLS LAST, warehouse_name
