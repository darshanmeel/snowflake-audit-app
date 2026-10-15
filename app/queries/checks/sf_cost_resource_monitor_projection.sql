-- query_id: sf_cost_resource_monitor_projection
-- title: Resource monitors on track to hit their quota before the cycle resets
-- domain: cost   tier: standard
-- entity: resource monitors = monitor_name
-- windowed: no
-- pre: SHOW RESOURCE MONITORS
-- reads: SHOW RESOURCE MONITORS
-- requires: MONITOR on the resource monitors (SHOW lists only the monitors the role can see)
-- params: :crit_days (default 3) days: a monitor that will run out within this many days reads CRITICAL when it
--   suspends warehouses
-- empty_if: role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The output columns frequency, start_time, used_credits and
--   credit_quota are the ones the docs describe for SHOW RESOURCE MONITORS; how a monitor's current cycle is
--   derived from start_time and frequency is worked out here, not reported by Snowflake.
-- read_this: one row = one resource monitor (name). used_pct is used credits of the quota. The cycle is worked out
--   from start_time and frequency; daily_rate is used credits divided by the days elapsed in the cycle (at least
--   one), projected_pct is that rate over the whole cycle as a percent of the quota, and days_to_quota is
--   how long the remaining credits last at that rate. has_suspend is TRUE when the monitor stops warehouses
--   at some percent, not only notifies.
-- healthy: status = OK when the monitor is below its quota and its projection for the cycle stays under it.
-- investigate_if: WARN when the projection reaches the quota before the cycle resets (or the monitor only
--   notifies); CRITICAL when it will be within :crit_days days and the monitor suspends warehouses. A monitor already
--   at its quota reads OK here: sf_cost_resource_monitor_coverage owns that finding. NOT_ASSESSED when the monitor has no quota or no reset cycle.
-- actions: 1) ask the warehouse owners whether the pace is expected before the month end (free); 2) raise the quota
--   or move a heavy job to the next cycle, knowing the monitor will suspend warehouses at its limit (spend);
--   3) add a notify step at 75 percent so the owners hear before the stop (config)
-- next: sf_cost_resource_monitor_coverage
-- not_assessed_reasons: no_quota: the monitor has no credit quota; no_reset_cycle: the monitor never resets (NEVER
--   or no start time) so a cycle projection does not apply; not_started: the monitor's start time is in the future
-- caveats: SHOW RESOURCE MONITORS lists only monitors the role can see. used_credits is live at export time
--   while the cycle days are counted to the start of the export date, so the pace is slightly high early in
--   a day. A straight line misses weekday and month-end peaks. Monitors cap warehouses only; serverless, storage
--   and AI credits are not capped by them and are not in used_credits.
WITH rm AS (
  SELECT m."name" AS monitor_name, UPPER(TO_VARCHAR(m."level")) AS monitor_level,
         UPPER(TO_VARCHAR(m."frequency")) AS frequency,
         TRY_TO_TIMESTAMP_LTZ(TO_VARCHAR(m."start_time")) AS start_ts,
         TRY_TO_DOUBLE(TO_VARCHAR(m."credit_quota")) AS credit_quota,
         TRY_TO_DOUBLE(TO_VARCHAR(m."used_credits")) AS used_credits,
         (NULLIF(NULLIF(TO_VARCHAR(m."suspend_at"), 'null'), '') IS NOT NULL
          OR NULLIF(NULLIF(TO_VARCHAR(m."suspend_immediately_at"), 'null'), '') IS NOT NULL) AS has_suspend
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) m
),
c0 AS (
  SELECT rm.*,
         CASE frequency WHEN 'DAILY' THEN 1 WHEN 'WEEKLY' THEN 7 WHEN 'MONTHLY' THEN 1 WHEN 'YEARLY' THEN 12 END AS step,
         frequency IN ('MONTHLY', 'YEARLY') AS by_month
  FROM rm
),
c1 AS (
  SELECT c0.*,
         FLOOR(IFF(by_month, DATEDIFF('month', start_ts, __AS_OF_DATE__), DATEDIFF('day', start_ts, __AS_OF_DATE__)) / step) AS n0
  FROM c0
),
c2 AS (
  SELECT c1.*,
         IFF(IFF(by_month, DATEADD('month', n0 * step, start_ts), DATEADD('day', n0 * step, start_ts)) > __AS_OF_DATE__,
             n0 - 1, n0) AS n
  FROM c1
),
c3 AS (
  SELECT c2.*,
         IFF(by_month, DATEADD('month', n * step, start_ts), DATEADD('day', n * step, start_ts)) AS cycle_start,
         IFF(by_month, DATEADD('month', (n + 1) * step, start_ts), DATEADD('day', (n + 1) * step, start_ts)) AS next_reset
  FROM c2
),
s AS (
  SELECT c3.*, 100 * used_credits / NULLIF(credit_quota, 0) AS used_pct,
         GREATEST(DATEDIFF('day', cycle_start, __AS_OF_DATE__), 1) AS elapsed_days,
         DATEDIFF('day', cycle_start, next_reset) AS cycle_days
  FROM c3
),
p AS (
  SELECT s.*, used_credits / elapsed_days AS daily_rate,
         100 * used_credits / elapsed_days * cycle_days / NULLIF(credit_quota, 0) AS projected_pct,
         (credit_quota - used_credits) / NULLIF(used_credits / elapsed_days, 0) AS days_to_quota
  FROM s
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, monitor_name, monitor_level, frequency, credit_quota,
       used_credits, used_pct, cycle_start, next_reset, daily_rate, projected_pct, days_to_quota,
       COALESCE(has_suspend, FALSE) AS has_suspend,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(used_pct < 100 AND projected_pct >= 100,
             'on pace for ' || ROUND(projected_pct) || ' percent of the quota before the reset', NULL),
         IFF(NOT COALESCE(has_suspend, FALSE), 'notifies only, does not suspend', NULL)), '; ') AS reasons,
       CASE WHEN credit_quota IS NULL OR credit_quota <= 0 THEN 'no_quota'
            WHEN start_ts IS NULL OR step IS NULL THEN 'no_reset_cycle'
            WHEN start_ts > __AS_OF_DATE__ THEN 'not_started' END AS not_assessed_reason,
       CASE
         WHEN credit_quota IS NULL OR credit_quota <= 0 OR start_ts IS NULL OR step IS NULL
              OR start_ts > __AS_OF_DATE__ THEN 'NOT_ASSESSED'
         WHEN used_pct >= 100 THEN 'OK'
         WHEN projected_pct >= 100 AND days_to_quota <= :crit_days AND COALESCE(has_suspend, FALSE) THEN 'CRITICAL'
         WHEN projected_pct >= 100 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM p
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END,
         projected_pct DESC NULLS LAST, monitor_name
