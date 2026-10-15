-- query_id: sf_task_alerts
-- title: Alerts that fail, and what alerts cost
-- domain: jobs_pipelines   tier: standard
-- entity: alerts = alert_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ALERT_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_ALERT_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_failure_pct (default 5) failure pct: at or above this the row reads WARN;
--   :crit_failure_pct (default 25) failure pct: at or above this the row reads CRITICAL;
--   :crit_consecutive_failures (default 3) consecutive failures: at or above this the row reads
--   CRITICAL; :warn_usd (default 20) usd: at or above this the row reads WARN; :crit_usd (default 200)
--   usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one alert (database.schema.alert). evaluations are finished checks of its
--   condition; triggered ran the action; failed_runs are FAILED, CONDITION_FAILED or ACTION_FAILED.
--   Credits are serverless alert credits plus the warehouse credits of its condition and action
--   queries. An alert that fails never notifies: the problem it watches goes unseen.
-- healthy: status = OK when the alert did not fail and costs under warn_usd.
-- investigate_if: WARN when failure_pct >= warn_failure_pct, the latest evaluation failed, or
--   est_alert_usd_list >= warn_usd; CRITICAL when failure_pct >= crit_failure_pct, consecutive_failures
--   >= crit_consecutive_failures, or est_alert_usd_list >= crit_usd.
-- actions: 1) fix the SQL or grants behind last_error_code (free); 2) evaluate the condition less
--   often, or over new rows only with SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME() (free); 3) move
--   a warehouse alert to serverless so it does not wake a warehouse (config).
-- next: none
-- caveats: the alert id comes from SERVERLESS_ALERT_HISTORY, so it is empty for warehouse alerts.
--   ALERT_HISTORY lags up to 3 hours. Warehouse credits exclude idle time.
WITH a AS (
  SELECT database_name || '.' || schema_name || '.' || name AS alert_full_name,
         name AS alert_name, database_name, schema_name, state, error_code,
         scheduled_time, completed_time, condition_query_id, action_query_id,
         state IN ('FAILED', 'CONDITION_FAILED', 'ACTION_FAILED') AS is_failed
  FROM SNOWFLAKE.ACCOUNT_USAGE.ALERT_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND state NOT IN ('SCHEDULED', 'EXECUTING')
),
attr AS (
  SELECT COALESCE(root_query_id, query_id) AS root_id,
         SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY 1
),
last_ok AS (
  SELECT alert_full_name, MAX(IFF(NOT is_failed, scheduled_time, NULL)) AS last_ok_time
  FROM a GROUP BY 1
),
h AS (
  SELECT a.alert_full_name, MAX(a.alert_name) AS alert_name, MAX(a.database_name) AS database_name,
         MAX(a.schema_name) AS schema_name,
         COUNT(*) AS evaluations,
         COUNT_IF(a.state = 'TRIGGERED') AS triggered,
         COUNT_IF(a.state = 'CONDITION_FALSE') AS condition_false,
         COUNT_IF(a.is_failed) AS failed_runs,
         COUNT_IF(a.is_failed AND a.scheduled_time > COALESCE(l.last_ok_time, '1970-01-01'::TIMESTAMP_LTZ))
           AS consecutive_failures,
         MAX_BY(a.state, a.scheduled_time) AS last_state,
         MAX(a.completed_time) AS last_run_time,
         MAX_BY(a.error_code, IFF(a.is_failed, a.scheduled_time, NULL)) AS last_error_code,
         SUM(COALESCE(ca.credits, 0) + COALESCE(aa.credits, 0)) AS warehouse_credits
  FROM a
  JOIN last_ok l ON l.alert_full_name = a.alert_full_name
  LEFT JOIN attr ca ON ca.root_id = a.condition_query_id
  LEFT JOIN attr aa ON aa.root_id = a.action_query_id
  GROUP BY a.alert_full_name
),
sl AS (
  SELECT database_name || '.' || schema_name || '.' || alert_name AS alert_full_name,
         MAX(TO_VARCHAR(alert_id)) AS alert_id, SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used))) AS serverless_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_ALERT_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
scored AS (
  SELECT h.*, sl.alert_id, COALESCE(sl.serverless_credits, 0) AS serverless_credits,
         h.warehouse_credits + COALESCE(sl.serverless_credits, 0) AS credits,
         (h.warehouse_credits + COALESCE(sl.serverless_credits, 0)) * __CREDIT_PRICE__ AS usd,
         100 * h.failed_runs / NULLIF(h.evaluations, 0) AS failure_pct
  FROM h LEFT JOIN sl ON sl.alert_full_name = h.alert_full_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       alert_full_name, alert_name, alert_id, database_name, schema_name,
       IFF(serverless_credits > 0, 'serverless', 'warehouse') AS compute_kind,
       evaluations, triggered, condition_false, failed_runs, failure_pct, consecutive_failures,
       last_state, last_run_time, last_error_code,
       warehouse_credits, serverless_credits, credits,
       usd AS est_alert_usd_list, usd / NULLIF(evaluations, 0) AS est_usd_per_evaluation,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       failed_runs || ' of ' || evaluations || ' evaluations failed; ' || ROUND(credits, 2) || ' credits'
         AS alert_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL AND failed_runs = 0 THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN failure_pct >= :crit_failure_pct OR consecutive_failures >= :crit_consecutive_failures
           OR usd >= :crit_usd THEN 'CRITICAL'
         WHEN (failed_runs > 0 AND failure_pct >= :warn_failure_pct)
           OR last_state IN ('FAILED', 'CONDITION_FAILED', 'ACTION_FAILED')
           OR usd >= :warn_usd THEN 'WARN'
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, failed_runs DESC, credits DESC
