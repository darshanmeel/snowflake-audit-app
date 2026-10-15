-- query_id: sf_dt_refresh_failures_and_lag
-- title: Dynamic tables that fail, fall behind or refresh in full
-- domain: jobs_pipelines   tier: standard
-- entity: dynamic tables = dt_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_failure_pct (default 5) failure pct: at or above this the row reads WARN;
--   :crit_failure_pct (default 25) failure pct: at or above this the row reads CRITICAL;
--   :crit_consecutive_failures (default 3) consecutive failures: at or above this the row reads
--   CRITICAL; :warn_lag_breach_pct (default 10) lag breach pct: at or above this the row reads WARN;
--   :crit_lag_breach_pct (default 50) lag breach pct: at or above this the row reads CRITICAL;
--   :warn_full_pct (default 50) full pct: at or above this the row reads WARN; :min_refreshes (default
--   5) refreshes: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one dynamic table. failed_refreshes are FAILED (its own error); upstream_failed
--   are refreshes skipped because an input failed. observed_lag_seconds is how stale the table was just
--   before each successful refresh finished (end of refresh minus the previous data timestamp);
--   lag_breach_pct is the share of refreshes where that exceeded target_lag_seconds. full_pct is the
--   share of data-changing refreshes that rebuilt the whole table (refresh_action FULL).
-- healthy: status = OK when no refresh failed, lag stays under target and refreshes are incremental.
-- investigate_if: WARN when failure_pct >= warn_failure_pct, the latest refresh failed, lag_breach_pct
--   >= warn_lag_breach_pct, or full_pct >= warn_full_pct; CRITICAL when failure_pct >=
--   crit_failure_pct, consecutive_failures >= crit_consecutive_failures or lag_breach_pct >=
--   crit_lag_breach_pct.
-- actions: 1) fix the error in last_state_message, or the upstream table when upstream_failed (free);
--   2) run SHOW DYNAMIC TABLES and read refresh_mode_reason: rewrite the query so it can refresh
--   incrementally (free); 3) set a realistic TARGET_LAG, or DOWNSTREAM for intermediate tables, or give
--   the refresh warehouse more size when lag is missed (config / spend).
-- next: none
-- caveats: target_lag_seconds is empty for TARGET_LAG = DOWNSTREAM, so those rows cannot breach.
--   REINITIALIZE refreshes (after a definition change) are counted apart from FULL. The table id is the
--   current id for the name. The history lags up to 3 hours. last_state_message has emails and quoted
--   values replaced, so no data from the table is stored.
WITH __INCLUDE_sf_dt_dim__,
r AS (
  SELECT database_name || '.' || schema_name || '.' || name AS dt_full_name,
         name AS dt_name, database_name, schema_name, state, state_code, state_message, refresh_action,
         refresh_trigger, target_lag_sec, data_timestamp, refresh_start_time, refresh_end_time,
         DATEDIFF('millisecond', refresh_start_time, refresh_end_time) / 1000 AS refresh_seconds,
         state IN ('FAILED', 'UPSTREAM_FAILED', 'CANCELLED') AS is_bad
  FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
  WHERE data_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND data_timestamp < __AS_OF_DATE__
    AND state NOT IN ('SCHEDULED', 'EXECUTING')
),
succ AS (
  SELECT dt_full_name, target_lag_sec, refresh_end_time,
         DATEDIFF('second', LAG(data_timestamp) OVER (PARTITION BY dt_full_name ORDER BY data_timestamp),
                  refresh_end_time) AS observed_lag_seconds
  FROM r WHERE state = 'SUCCEEDED'
),
lagged AS (
  SELECT dt_full_name,
         MEDIAN(observed_lag_seconds) AS p50_observed_lag_seconds,
         APPROX_PERCENTILE(observed_lag_seconds, 0.9) AS p90_observed_lag_seconds,
         MAX(observed_lag_seconds) AS max_observed_lag_seconds,
         COUNT(observed_lag_seconds) AS lag_samples,
         COUNT_IF(observed_lag_seconds > target_lag_sec) AS lag_breaches
  FROM succ GROUP BY 1
),
last_ok AS (
  SELECT dt_full_name, MAX(IFF(state = 'SUCCEEDED', data_timestamp, NULL)) AS last_success_data_timestamp
  FROM r GROUP BY 1
),
t AS (
  SELECT r.dt_full_name, MAX(r.dt_name) AS dt_name, MAX(r.database_name) AS database_name,
         MAX(r.schema_name) AS schema_name,
         COUNT(*) AS refreshes,
         COUNT_IF(r.state = 'SUCCEEDED') AS succeeded_refreshes,
         COUNT_IF(r.state = 'FAILED') AS failed_refreshes,
         COUNT_IF(r.state = 'UPSTREAM_FAILED') AS upstream_failed_refreshes,
         COUNT_IF(r.state = 'CANCELLED') AS cancelled_refreshes,
         COUNT_IF(r.state = 'SKIPPED') AS skipped_refreshes,
         COUNT_IF(r.is_bad AND r.data_timestamp > COALESCE(l.last_success_data_timestamp, '1970-01-01'::TIMESTAMP_LTZ))
           AS consecutive_failures,
         COUNT_IF(r.state = 'SUCCEEDED' AND r.refresh_action = 'INCREMENTAL') AS incremental_refreshes,
         COUNT_IF(r.state = 'SUCCEEDED' AND r.refresh_action = 'FULL') AS full_refreshes,
         COUNT_IF(r.state = 'SUCCEEDED' AND r.refresh_action = 'REINITIALIZE') AS reinitialize_refreshes,
         COUNT_IF(r.state = 'SUCCEEDED' AND r.refresh_action = 'NO_DATA') AS no_data_refreshes,
         COUNT_IF(r.refresh_trigger = 'MANUAL') AS manual_refreshes,
         MEDIAN(IFF(r.state = 'SUCCEEDED' AND r.refresh_action <> 'NO_DATA', r.refresh_seconds, NULL)) AS p50_refresh_seconds,
         MAX_BY(r.target_lag_sec, r.data_timestamp) AS target_lag_seconds,
         MAX_BY(r.state, r.data_timestamp) AS last_state,
         MAX(r.refresh_end_time) AS last_refresh_time,
         MAX(l.last_success_data_timestamp) AS last_success_data_timestamp,
         MAX_BY(r.state_code, IFF(r.is_bad, r.data_timestamp, NULL)) AS last_state_code,
         MAX_BY(r.state_message, IFF(r.is_bad, r.data_timestamp, NULL)) AS last_state_message
  FROM r JOIN last_ok l ON l.dt_full_name = r.dt_full_name
  GROUP BY r.dt_full_name
),
scored AS (
  SELECT t.*, lg.p50_observed_lag_seconds, lg.p90_observed_lag_seconds, lg.max_observed_lag_seconds,
         lg.lag_breaches, d.dt_id, d.owner,
         100 * (failed_refreshes + upstream_failed_refreshes + cancelled_refreshes) / NULLIF(refreshes, 0) AS failure_pct,
         100 * lg.lag_breaches / NULLIF(lg.lag_samples, 0) AS lag_breach_pct,
         100 * full_refreshes / NULLIF(full_refreshes + incremental_refreshes, 0) AS full_pct
  FROM t
  LEFT JOIN lagged lg ON lg.dt_full_name = t.dt_full_name
  LEFT JOIN sf_dt_dim d ON d.dt_full_name = t.dt_full_name
),
graded AS (
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       dt_full_name, dt_name, dt_id, database_name, schema_name, owner,
       refreshes, succeeded_refreshes, failed_refreshes, upstream_failed_refreshes, cancelled_refreshes,
       skipped_refreshes, failure_pct, consecutive_failures, last_state, last_refresh_time,
       last_success_data_timestamp, last_state_code, -- emails and quoted literals out: an error can quote a value from the data
       LEFT(REGEXP_REPLACE(REGEXP_REPLACE(last_state_message, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'), '''[^'']*''', '?'), 500) AS last_state_message,
       incremental_refreshes, full_refreshes, reinitialize_refreshes, no_data_refreshes, manual_refreshes,
       full_pct, p50_refresh_seconds, target_lag_seconds, p50_observed_lag_seconds,
       p90_observed_lag_seconds, max_observed_lag_seconds, lag_breaches, lag_breach_pct,
       (failed_refreshes + upstream_failed_refreshes + cancelled_refreshes) || ' of ' || refreshes
         || ' refreshes failed; ' || COALESCE(ROUND(lag_breach_pct) || '% over target lag; ', '')
         || COALESCE(ROUND(full_pct) || '% full refreshes', '') AS dt_reason,
       CASE
         WHEN failure_pct >= :crit_failure_pct OR consecutive_failures >= :crit_consecutive_failures
           OR (refreshes >= :min_refreshes AND lag_breach_pct >= :crit_lag_breach_pct) THEN 'CRITICAL'
         WHEN (failed_refreshes + upstream_failed_refreshes + cancelled_refreshes > 0 AND failure_pct >= :warn_failure_pct)
           OR last_state IN ('FAILED', 'UPSTREAM_FAILED') THEN 'WARN'
         WHEN refreshes < :min_refreshes THEN 'NOT_ASSESSED'
         WHEN lag_breach_pct >= :warn_lag_breach_pct
           OR (full_refreshes >= :min_refreshes AND full_pct >= :warn_full_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
)
SELECT graded.*, IFF(status = 'NOT_ASSESSED', 'too_few_refreshes', NULL) AS not_assessed_reason
FROM graded
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, failure_pct DESC NULLS LAST, lag_breach_pct DESC NULLS LAST
