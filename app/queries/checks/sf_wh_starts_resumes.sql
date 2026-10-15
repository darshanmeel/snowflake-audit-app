-- query_id: sf_wh_starts_resumes
-- title: Warehouse resumes, suspends and cluster starts
-- domain: compute   tier: standard
-- windowed: yes
-- entity: warehouses = warehouse_id
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (or USAGE_VIEWER and GOVERNANCE_VIEWER)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_resumes_per_day (default 200) resumes per day at or above which the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse with a start, stop or provisioning wait in the window. resumes
--   counts RESUME_WAREHOUSE actions (a STARTED and a COMPLETED row of one action count once), split into
--   auto_resumes (WAREHOUSE_AUTORESUME: a statement woke it) and manual_resumes (WAREHOUSE_RESUME: an
--   ALTER WAREHOUSE ... RESUME). suspends splits the same way into auto, manual and resource-monitor
--   suspends (a drop also logs a suspend, counted in suspends only). clusters_added counts clusters 2
--   and up starting on a multi-cluster warehouse. provisioning_wait_s adds up the time queries waited for the warehouse to come up
--   (QUERY_HISTORY.QUEUED_PROVISIONING_TIME); queries_waiting_provisioning counts them, and
--   provisioning_p95_s is the 95th percentile wait among them, the closest view of how long a resume takes.
-- healthy: status = OK when the warehouse resumes under :warn_resumes_per_day times a day
-- investigate_if: WARN when resumes_per_day >= :warn_resumes_per_day: the warehouse starts and stops all
--   day, so each start pays the 60-second minimum and users wait for provisioning
-- actions: 1) find what wakes it (polls, BI refreshes, task schedules) and batch them (free); 2) raise
--   AUTO_SUSPEND so close-together bursts share one run (config); 3) move tiny, frequent jobs onto
--   serverless tasks billed per second (config)
-- next: sf_wh_resume_churn, sf_wh_auto_suspend_tuning
-- caveats: the view logs a STARTED row and then a WAREHOUSE_CONSISTENT row (not a COMPLETED row of the same
--   event), and several STARTED rows can merge into one, so resume durations cannot be paired reliably and
--   are not shown; provisioning waits stand in for them. Adaptive warehouses may log no resume events
--   but still show provisioning waits. Events lag up to 3 h and QUERY_HISTORY up to 45 min; both keep 365 days.
--   Totals per warehouse, so days with no events are not listed.
WITH ev AS (
  -- level 0 = the warehouse, n = cluster n; collapse repeats of the same kind (STARTED then COMPLETED)
  SELECT warehouse_id, warehouse_name, timestamp, event_reason,
         IFF(event_name IN ('RESUME_WAREHOUSE', 'SUSPEND_WAREHOUSE'), 0, cluster_number) AS lvl,
         IFF(event_name IN ('RESUME_WAREHOUSE', 'RESUME_CLUSTER', 'SPINUP_CLUSTER')
             OR event_reason = 'MULTICLUSTER_SPINUP', 'R', 'S') AS kind,
         IFF(COALESCE(event_state, 'COMPLETED') = 'STARTED', 0, 1) AS state_order
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
    AND (event_name IN ('RESUME_WAREHOUSE', 'SUSPEND_WAREHOUSE')
         -- a scale-in must end the cluster's run, or its next spin-up merges into the last one
         OR ((event_name IN ('RESUME_CLUSTER', 'SPINUP_CLUSTER', 'SUSPEND_CLUSTER', 'SPINDOWN_CLUSTER')
              OR event_reason IN ('MULTICLUSTER_SPINUP', 'MULTICLUSTER_SPINDOWN'))
             AND event_name NOT IN ('CLUSTER_CONSISTENT', 'WAREHOUSE_CONSISTENT') AND cluster_number > 1))
),
seq AS (
  SELECT ev.*, LAG(kind) OVER (PARTITION BY warehouse_id, lvl ORDER BY timestamp, state_order) AS prev_kind
  FROM ev
),
edges AS (
  SELECT * FROM seq WHERE prev_kind IS NULL OR prev_kind <> kind
),
e AS (
  SELECT warehouse_id, MAX_BY(warehouse_name, timestamp) AS warehouse_name,
         COUNT_IF(lvl = 0 AND kind = 'R') AS resumes,
         COUNT_IF(lvl = 0 AND kind = 'R' AND event_reason = 'WAREHOUSE_AUTORESUME') AS auto_resumes,
         COUNT_IF(lvl = 0 AND kind = 'R' AND event_reason = 'WAREHOUSE_RESUME') AS manual_resumes,
         COUNT_IF(lvl = 0 AND kind = 'S') AS suspends,
         COUNT_IF(lvl = 0 AND kind = 'S' AND event_reason = 'WAREHOUSE_AUTOSUSPEND') AS auto_suspends,
         COUNT_IF(lvl = 0 AND kind = 'S' AND event_reason = 'WAREHOUSE_SUSPEND') AS manual_suspends,
         COUNT_IF(lvl = 0 AND kind = 'S' AND event_reason = 'RESOURCE_MONITOR_SUSPEND') AS monitor_suspends,
         COUNT_IF(lvl > 0 AND kind = 'R') AS clusters_added,
         MAX(IFF(lvl = 0 AND kind = 'R', timestamp, NULL)) AS last_resume_time
  FROM edges
  GROUP BY 1
),
q AS (
  SELECT warehouse_id, MAX_BY(warehouse_name, start_time) AS warehouse_name,
         COUNT_IF(queued_provisioning_time > 0) AS queries_waiting_provisioning,
         SUM(queued_provisioning_time) / 1000 AS provisioning_wait_s,
         APPROX_PERCENTILE(IFF(queued_provisioning_time > 0, queued_provisioning_time, NULL), 0.95) / 1000 AS provisioning_p95_s
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
  GROUP BY 1
  HAVING COUNT_IF(queued_provisioning_time > 0) > 0
),
j AS (
  SELECT TO_VARCHAR(COALESCE(e.warehouse_id, q.warehouse_id)) AS warehouse_id,
         COALESCE(e.warehouse_name, q.warehouse_name) AS warehouse_name,
         COALESCE(e.resumes, 0) AS resumes, COALESCE(e.auto_resumes, 0) AS auto_resumes,
         COALESCE(e.manual_resumes, 0) AS manual_resumes, COALESCE(e.suspends, 0) AS suspends,
         COALESCE(e.auto_suspends, 0) AS auto_suspends, COALESCE(e.manual_suspends, 0) AS manual_suspends,
         COALESCE(e.monitor_suspends, 0) AS monitor_suspends, COALESCE(e.clusters_added, 0) AS clusters_added,
         e.last_resume_time,
         COALESCE(q.queries_waiting_provisioning, 0) AS queries_waiting_provisioning,
         COALESCE(q.provisioning_wait_s, 0) AS provisioning_wait_s, q.provisioning_p95_s
  FROM e FULL OUTER JOIN q ON q.warehouse_id = e.warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       resumes, ROUND(resumes / :period_days, 1) AS resumes_per_day, auto_resumes, manual_resumes,
       suspends, auto_suspends, manual_suspends, monitor_suspends, clusters_added, last_resume_time,
       queries_waiting_provisioning, ROUND(provisioning_wait_s, 1) AS provisioning_wait_s,
       ROUND(provisioning_p95_s, 1) AS provisioning_p95_s,
       CASE WHEN resumes / :period_days >= :warn_resumes_per_day THEN 'WARN' ELSE 'OK' END AS status
FROM j
ORDER BY resumes DESC, warehouse_name
