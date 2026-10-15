-- query_id: sf_ai_spcs_pool_no_live_service
-- title: Compute pools billing with no running service or job
-- domain: serving_ai   tier: standard
-- entity: compute pools = compute_pool_name
-- windowed: yes
-- money: est_wasted_usd_list
-- pre: SHOW SERVICES IN ACCOUNT
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SERVICES,
--   SNOWFLAKE.ACCOUNT_USAGE.COMPUTE_POOLS, SNOWFLAKE.ACCOUNT_USAGE.NOTEBOOKS_CONTAINER_RUNTIME_HISTORY,
--   SHOW SERVICES IN ACCOUNT
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; the role should see the services SHOW lists (USAGE,
--   MONITOR, OPERATE or OWNERSHIP) or the failed-service column reads empty
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 20) usd: idle spend at or above this reads WARN; :crit_usd (default 200) usd:
--   idle spend at or above this on a pool with no live service all window reads CRITICAL
-- empty_if: no_activity, view_missing, role_cannot_see
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That SERVICES lists every service whatever the role, and
--   that a suspended service leaves the pool up only until the pool's own auto-suspend, are not stated in the
--   docs. Pools are matched to services by pool id, and by name only when the id is missing.
-- not_assessed_reasons: unpriced: no credit price is available for the window, so idle spend cannot be
--   priced; services_not_visible: SERVICES has no rows although SHOW SERVICES lists services, so live services
--   are not known; runs_jobs: a job service existed on the pool in the window and a job has no end time in
--   SERVICES, so its idle time cannot be told from its run time
-- read_this: one row = one compute pool with credits in the window (a dropped pool keeps its spend). live_services
--   are its services not dropped and not suspended (jobs apart). An hour is idle when it comes after
--   the last service stopped (plus the pool's auto-suspend), no service is live and the notebook
--   container runtime billed nothing on the pool that hour. est_wasted_usd_list is those hours: a slice of
--   est_usd_list, never added to it.
-- healthy: status = OK when a service is live on the pool, or the pool billed little while idle.
-- investigate_if: WARN when idle spend is at least warn_usd; CRITICAL when the pool had no live service all window and idle
--   spend is at least crit_usd.
-- actions: 1) DROP COMPUTE POOL on pools nothing runs on (free); 2) set AUTO_SUSPEND_SECS on the pool so it
--   stops between uses (config); 3) lower MIN_NODES to 0 or 1 (config).
-- next: sf_ai_compute_pools_config, sf_ai_spcs_costs_outside_pools
-- caveats: Pool spend stays on the Snowpark Container Services spend check; idle is a slice of it. System
--   and app-owned pools are left out (they have their own pages). Job pools are not judged for idle time.
--   Block storage and services that never suspend are on the container costs check. SHOW SERVICES lists only services the
--   role can see: an empty list reads failed_services empty, never "none failing". A pool with no service
--   at all reads idle from the window start; that needs SERVICES and SHOW SERVICES both empty. The history lags up to
--   3 hours.
WITH h AS (
  SELECT COALESCE(TO_VARCHAR(compute_pool_id), 'N:' || UPPER(compute_pool_name)) AS pool_key, MAX_BY(compute_pool_name, start_time) AS compute_pool_name,
         MAX(compute_pool_id) AS compute_pool_id, DATE_TRUNC('hour', start_time) AS hr, SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND NOT COALESCE(is_exclusive, FALSE) AND LEFT(UPPER(compute_pool_name), 20) <> 'SYSTEM_COMPUTE_POOL_'
  GROUP BY 1, 4
),
nb AS (
  SELECT COALESCE(TO_VARCHAR(compute_pool_id), 'N:' || UPPER(compute_pool_name)) AS pool_key, DATE_TRUNC('hour', start_time) AS hr
  FROM SNOWFLAKE.ACCOUNT_USAGE.NOTEBOOKS_CONTAINER_RUNTIME_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
  HAVING SUM(credits) > 0
),
sv AS (
  SELECT COALESCE(TO_VARCHAR(compute_pool_id), 'N:' || UPPER(compute_pool_name)) AS pool_key,
         COUNT_IF(deleted IS NULL AND NOT COALESCE(is_job, FALSE)
                  AND (last_suspended IS NULL OR last_resumed > last_suspended)) AS live_services,
         MAX(IFF(NOT COALESCE(is_job, FALSE), COALESCE(deleted, last_suspended), NULL)) AS last_service_stop,
         COUNT_IF(COALESCE(is_job, FALSE) AND created < __AS_OF_DATE__
                  AND COALESCE(deleted, __AS_OF_DATE__) >= DATEADD(day, -:period_days, __AS_OF_DATE__)) AS jobs_in_window
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVICES
  GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS service_rows FROM SNOWFLAKE.ACCOUNT_USAGE.SERVICES
),
cp AS (
  SELECT COALESCE(TO_VARCHAR(id), 'N:' || UPPER(name)) AS pool_key, MAX_BY(auto_suspend_secs, COALESCE(deleted, last_altered, created)) AS auto_suspend_secs
  FROM SNOWFLAKE.ACCOUNT_USAGE.COMPUTE_POOLS
  GROUP BY 1
),
sh AS (
  SELECT UPPER(TO_VARCHAR("compute_pool")) AS pool_name_key, COUNT_IF(UPPER(TO_VARCHAR("status")) = 'FAILED') AS failed_services
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
  GROUP BY 1
),
sh_seen AS (
  SELECT COUNT(*) AS show_rows FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
),
p AS (
  SELECT h.pool_key, MAX(h.compute_pool_name) AS compute_pool_name, MAX(h.compute_pool_id) AS compute_pool_id,
         SUM(h.credits) AS credits, COUNT_IF(h.credits > 0) AS active_hours,
         COALESCE(MAX(sv.live_services), 0) AS live_services,
         MAX(sv.last_service_stop) AS last_service_stop, COALESCE(MAX(sv.jobs_in_window), 0) AS jobs_in_window,
         SUM(IFF(COALESCE(sv.live_services, 0) = 0 AND COALESCE(sv.jobs_in_window, 0) = 0 AND nb.hr IS NULL
                 AND h.hr >= DATEADD('second', COALESCE(cp.auto_suspend_secs, 0),
                                     COALESCE(sv.last_service_stop, CAST(DATEADD(day, -:period_days, __AS_OF_DATE__) AS TIMESTAMP_LTZ))),
                 h.credits, 0)) AS idle_credits,
         COUNT_IF(COALESCE(sv.live_services, 0) = 0 AND COALESCE(sv.jobs_in_window, 0) = 0 AND nb.hr IS NULL
                  AND h.hr >= DATEADD('second', COALESCE(cp.auto_suspend_secs, 0),
                                      COALESCE(sv.last_service_stop, CAST(DATEADD(day, -:period_days, __AS_OF_DATE__) AS TIMESTAMP_LTZ)))
                  AND h.credits > 0) AS idle_hours
  FROM h
  LEFT JOIN sv ON sv.pool_key = h.pool_key
  LEFT JOIN cp ON cp.pool_key = h.pool_key
  LEFT JOIN nb ON nb.pool_key = h.pool_key AND nb.hr = h.hr
  GROUP BY h.pool_key
),
s AS (
  SELECT p.*, sh.failed_services AS failed_services_seen, seen.service_rows, sh_seen.show_rows,
         p.credits * __CREDIT_PRICE__ AS usd, p.idle_credits * __CREDIT_PRICE__ AS idle_usd,
         p.live_services = 0 AND p.jobs_in_window = 0 AND p.idle_hours > 0 AND p.idle_hours = p.active_hours AS idle_all_window,
         seen.service_rows = 0 AND sh_seen.show_rows > 0 AS services_blind
  FROM p
  LEFT JOIN sh ON sh.pool_name_key = UPPER(p.compute_pool_name)
  CROSS JOIN seen CROSS JOIN sh_seen
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, compute_pool_name, TO_VARCHAR(compute_pool_id) AS compute_pool_id,
       live_services, last_service_stop, jobs_in_window,
       IFF(show_rows = 0, NULL, COALESCE(failed_services_seen, 0)) AS failed_services,
       active_hours, idle_hours, credits, idle_credits,
       usd AS est_usd_list,
       IFF(live_services = 0 AND jobs_in_window = 0 AND NOT services_blind, idle_usd, NULL) AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(idle_credits > 0, idle_hours || ' idle hours with no running service (' || ROUND(idle_credits, 1) || ' credits)', NULL),
         IFF(idle_all_window, 'no live service all window', NULL),
         IFF(failed_services_seen > 0, failed_services_seen || ' failed services', NULL)), '; ') AS reasons,
       CASE WHEN services_blind THEN 'services_not_visible'
            WHEN jobs_in_window > 0 AND live_services = 0 THEN 'runs_jobs'
            WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN services_blind THEN 'NOT_ASSESSED'
         WHEN jobs_in_window > 0 AND live_services = 0 THEN 'NOT_ASSESSED'
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN idle_all_window AND idle_usd >= :crit_usd THEN 'CRITICAL'
         WHEN idle_usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END, idle_credits DESC, credits DESC
