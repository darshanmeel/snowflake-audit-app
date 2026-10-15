-- query_id: sf_task_alerts_silenced
-- title: Alerts that were switched off or stopped evaluating
-- domain: jobs_pipelines   tier: standard
-- entity: alerts = alert_full_name
-- windowed: yes
-- pre: SHOW ALERTS IN ACCOUNT
-- reads: SHOW ALERTS IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.ALERT_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR, OPERATE or OWNERSHIP on the alerts
--   (SHOW ALERTS lists only those)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :stale_days (default 30) days: a suspended alert with no evaluation for this long reads stale
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. ALERT_HISTORY.WAS_AUTO_SUSPENDED marks the run that hit the
--   failure limit; it counts only while the alert is still suspended.
-- not_assessed_reasons: alerts_not_visible: alert runs exist in the history for alerts SHOW ALERTS does not
--   list (the role cannot see them, or they were dropped), so their current state is not known
-- read_this: one row = one alert that exists now, with its evaluations from the history. finding is
--   auto_suspended (Snowflake suspended it after repeated failures and it is still off), suspended_stale (off
--   and not evaluated for stale_days), started_not_evaluating (on, with a schedule, and no evaluation in
--   the window) or ok. An alert suspended before the window has no history rows: it is listed here from
--   SHOW, where the alerts check cannot see it. A not-visible row counts the alert names in the history
--   that SHOW did not list.
-- healthy: status = OK when the alert evaluates on its schedule.
-- investigate_if: WARN when a suspended alert has not evaluated for stale_days, or a started alert did not
--   evaluate in the window; CRITICAL when Snowflake auto-suspended it and it is still off.
-- actions: 1) read the last error in the alerts check, fix it, then ALTER ALERT ... RESUME (free);
--   2) drop alerts nobody needs (free); 3) set a warehouse and a schedule on a started alert that never runs
--   (config).
-- next: sf_task_alerts
-- caveats: SHOW lists only alerts the role can see; an empty list with runs in the history reads not assessed,
--   never "no silenced alerts"; alerts SHOW omits while the history shows them are counted in a not-assessed
--   row. The auto-suspend flag comes from ALERT_HISTORY only. An alert created inside the window is not judged as not evaluating. The
--   condition and action text are never read. ALERT_HISTORY lags up to 45 minutes.
WITH sa AS (
  SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS alert_full_name, "name" AS alert_name,
         "database_name" AS database_name, "schema_name" AS schema_name, "owner" AS alert_owner,
         "warehouse" AS warehouse_name, "schedule" AS alert_schedule, LOWER(TO_VARCHAR("state")) AS state,
         CAST("created_on" AS TIMESTAMP_LTZ) AS created_on
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
),
h AS (
  SELECT database_name || '.' || schema_name || '.' || name AS alert_full_name,
         COUNT_IF(scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)) AS evaluations_in_window,
         MAX(scheduled_time) AS last_evaluation,
         MAX_BY(COALESCE(was_auto_suspended, FALSE), scheduled_time) AS history_auto_suspended
  FROM SNOWFLAKE.ACCOUNT_USAGE.ALERT_HISTORY
  WHERE scheduled_time >= DATEADD(day, -(:period_days + :stale_days), __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND state NOT IN ('SCHEDULED', 'EXECUTING')
  GROUP BY 1
),
s AS (
  SELECT sa.*, COALESCE(h.evaluations_in_window, 0) AS evaluations_in_window, h.last_evaluation,
         sa.state = 'suspended' AND COALESCE(h.history_auto_suspended, FALSE) AS auto_suspended,
         sa.state = 'suspended' AND NOT COALESCE(h.history_auto_suspended, FALSE)
           AND (h.last_evaluation IS NULL OR h.last_evaluation < DATEADD(day, -:stale_days, __AS_OF_DATE__)) AS suspended_stale,
         sa.state = 'started' AND NULLIF(TRIM(sa.alert_schedule), '') IS NOT NULL
           AND COALESCE(h.evaluations_in_window, 0) = 0
           AND sa.created_on < DATEADD(day, -:period_days, __AS_OF_DATE__) AS not_evaluating
  FROM sa LEFT JOIN h ON h.alert_full_name = sa.alert_full_name
),
main AS (
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, alert_full_name, alert_name, database_name, schema_name,
         alert_owner, warehouse_name, alert_schedule, state, created_on, evaluations_in_window, last_evaluation,
         CASE WHEN auto_suspended THEN 'auto_suspended' WHEN suspended_stale THEN 'suspended_stale'
              WHEN not_evaluating THEN 'started_not_evaluating' ELSE 'ok' END AS finding,
         ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           IFF(auto_suspended, 'auto-suspended by Snowflake after repeated failures and still off', NULL),
           IFF(suspended_stale, 'suspended, last evaluated '
               || COALESCE(TO_VARCHAR(DATE(last_evaluation)), 'never in the history'), NULL),
           IFF(not_evaluating, 'started with a schedule but no evaluation in ' || :period_days || ' days', NULL)), '; ') AS reasons,
         CAST(NULL AS VARCHAR) AS not_assessed_reason,
         CASE WHEN auto_suspended THEN 'CRITICAL' WHEN suspended_stale OR not_evaluating THEN 'WARN' ELSE 'OK' END AS status
  FROM s
),
blind AS (
  -- The history shows alerts running that SHOW does not list: the role cannot see them (or they were dropped).
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
         CAST('(' || COUNT(*) || ' alerts in the history not listed by SHOW)' AS VARCHAR) AS alert_full_name, CAST(NULL AS VARCHAR) AS alert_name,
         CAST(NULL AS VARCHAR) AS database_name, CAST(NULL AS VARCHAR) AS schema_name, CAST(NULL AS VARCHAR) AS alert_owner,
         CAST(NULL AS VARCHAR) AS warehouse_name, CAST(NULL AS VARCHAR) AS alert_schedule, CAST(NULL AS VARCHAR) AS state,
         CAST(NULL AS TIMESTAMP_LTZ) AS created_on, CAST(NULL AS NUMBER) AS evaluations_in_window,
         CAST(NULL AS TIMESTAMP_LTZ) AS last_evaluation, CAST(NULL AS VARCHAR) AS finding, CAST(NULL AS VARCHAR) AS reasons,
         'alerts_not_visible' AS not_assessed_reason, 'NOT_ASSESSED' AS status
  FROM h
  WHERE h.evaluations_in_window > 0 AND h.alert_full_name NOT IN (SELECT alert_full_name FROM sa)
  HAVING COUNT(*) > 0
)
SELECT * FROM (
  SELECT * FROM main
  UNION ALL
  SELECT * FROM blind
)
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END, alert_full_name
