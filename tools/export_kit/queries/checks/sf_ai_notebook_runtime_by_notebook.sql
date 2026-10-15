-- query_id: sf_ai_notebook_runtime_by_notebook
-- title: Notebook container runtime spend by notebook and user, and sessions left running
-- domain: serving_ai   tier: standard
-- entity: notebooks = notebook_name, user_name
-- windowed: yes
-- money: est_within_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.NOTEBOOKS_CONTAINER_RUNTIME_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 10) spend usd: least a row needs before it can flag;
--   :warn_hours_per_day (default 12) hours: billed hours per active day at or above this flag a session left up;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one notebook run by one user (or by a schedule) on one compute pool. credits and
--   billed_hours come from the hourly rows with credits; hours_per_active_day is billed hours over the days
--   that had any. The $ is a share of the compute pool spend already on the compute pool page, so it is
--   shown as context and never added to it.
-- healthy: status = OK when a notebook's runtime is small, ends between sessions and is not growing fast.
-- investigate_if: WARN when a notebook spending at least :min_spend_usd averages :warn_hours_per_day billed
--   hours per active day (a kernel left up) or grew :warn_increase_pct percent on the window before.
-- actions: 1) shut down the notebook session when work ends (free); 2) set a short idle timeout on the
--   notebook (config); 3) move scheduled runs to a smaller pool or a warehouse (config)
-- next: sf_ai_compute_pools_config
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the credits cannot be priced
-- caveats: NOTEBOOK_EXECUTION_TIME_SECS is the runtime in the hour as reported, not proven idle time, so no
--   waste is claimed. The credits are the pool's credits split by notebook; they are not extra spend. Rows
--   with no user were not run interactively. SQL cells run on a warehouse, billed on the warehouse pages.
--   ACCOUNT_USAGE lags up to 3 hours.
WITH n AS (
  SELECT notebook_id, user_id, compute_pool_id,
         MAX(notebook_name) AS notebook_name, COALESCE(MAX(user_name), '(scheduled)') AS user_name,
         MAX(compute_pool_name) AS compute_pool_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS prev_credits,
         COUNT(DISTINCT IFF(credits > 0 AND start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__),
                            DATE_TRUNC('hour', start_time), NULL)) AS billed_hours,
         COUNT(DISTINCT IFF(credits > 0 AND start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__),
                            CAST(start_time AS DATE), NULL)) AS active_days,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), notebook_execution_time_secs, 0)) / 3600.0
           AS execution_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.NOTEBOOKS_CONTAINER_RUNTIME_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY notebook_id, user_id, compute_pool_id
),
s AS (
  SELECT n.*, billed_hours / NULLIF(active_days, 0) AS hours_per_active_day,
         100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         credits * __CREDIT_PRICE__ AS usd
  FROM n
  WHERE credits > 0 OR prev_credits > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, notebook_name, notebook_id, user_name, user_id,
       compute_pool_name, compute_pool_id, credits AS current_credits, prev_credits AS previous_credits, change_pct,
       billed_hours, active_days, hours_per_active_day, execution_hours,
       usd AS est_within_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(usd >= :min_spend_usd AND hours_per_active_day >= :warn_hours_per_day,
             'billed ' || ROUND(hours_per_active_day, 1) || ' hours per active day', NULL),
         IFF(usd >= :min_spend_usd AND prev_credits > 0 AND change_pct >= :warn_increase_pct, 'up ' || ROUND(change_pct, 0) || '% on the window before',
             NULL)), '; ') AS reasons,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd < :min_spend_usd THEN 'OK'
         WHEN hours_per_active_day >= :warn_hours_per_day
              OR (prev_credits > 0 AND change_pct >= :warn_increase_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY credits DESC, notebook_name
