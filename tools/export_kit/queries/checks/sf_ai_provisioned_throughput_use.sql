-- query_id: sf_ai_provisioned_throughput_use
-- title: Cortex provisioned throughput paid for against days the model was used
-- domain: serving_ai   tier: standard
-- entity: provisioned throughputs = throughput_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_idle_usd (default 25) idle usd: least idle spend a row needs before it can flag;
--   :warn_idle_pct (default 30) idle pct: idle days at or above this share of paid days read WARN;
--   :crit_idle_pct (default 70) idle pct: at or above this the row reads CRITICAL
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Model names in the usage views are matched to the
--   provisioned model by name, which is a lead only.
-- read_this: one row = one provisioned throughput (a model reserved for a term). ptu_credits are what the
--   reservation cost in the window. idle_days = paid days on which no usage row for that model shows up
--   in the AI-function or REST API views; idle_day_pct is their share of paid days. current = the window,
--   previous = the window before.
-- healthy: status = OK when the model is used on most paid days, or the idle spend is small.
-- investigate_if: WARN when idle_day_pct >= warn_idle_pct with idle spend >= min_idle_usd; CRITICAL when
--   idle_day_pct >= crit_idle_pct with idle spend >= min_idle_usd.
-- actions: 1) confirm with the owning team that the model is meant to be idle on those days, and check the
--   model name matches what callers send (free); 2) route more traffic through the reservation, or plan
--   not to renew at term end (config); 3) shrink PTU count or move to on-demand at renewal (spend).
-- next: sf_ai_spend_by_feature_reconciled
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced
-- caveats: idle_day_pct is a lead: usage is matched to the reservation by model name, and a caller that
--   uses another spelling shows as idle. Idle spend is possible waste in its own column and is part of
--   the spend, never added to it. Days are UTC, and days_to_term_end counts from the export date. A
--   readable but empty view means nothing is provisioned. If a usage view is not readable the whole check
--   is not assessed rather than showing idle days.
WITH days AS (
  SELECT DATEADD(day, -(seq4() + 1), __AS_OF_DATE__) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
),
ptu AS (
  SELECT provisioned_throughput_id, MAX(model_name) AS model_name, MAX(term_end_date) AS term_end_date,
         MAX(ptu_count) AS ptu_count,
         CAST(CONVERT_TIMEZONE('UTC', interval_start_time) AS DATE) AS usage_day,
         SUM(ptu_credits) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY
  WHERE interval_start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__
  GROUP BY provisioned_throughput_id, CAST(CONVERT_TIMEZONE('UTC', interval_start_time) AS DATE)
),
used AS (
  SELECT DISTINCT LOWER(model_name) AS model_key, usage_day
  FROM (
    SELECT model_name, CAST(CONVERT_TIMEZONE('UTC', start_time) AS DATE) AS usage_day
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
    WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    UNION ALL
    SELECT model_name, CAST(CONVERT_TIMEZONE('UTC', start_time) AS DATE)
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_REST_API_USAGE_HISTORY
    WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
      AND tokens > 0
  )
),
keys AS (
  SELECT provisioned_throughput_id, MAX(model_name) AS model_name, MAX(term_end_date) AS term_end_date,
         MAX(ptu_count) AS ptu_count
  FROM ptu
  GROUP BY provisioned_throughput_id
),
spine AS (
  SELECT k.provisioned_throughput_id, s.d, COALESCE(p.credits, 0) AS credits,
         u.usage_day IS NOT NULL AS model_used
  FROM keys k
  CROSS JOIN (SELECT d FROM days WHERE d >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__)) s
  LEFT JOIN ptu p ON p.provisioned_throughput_id = k.provisioned_throughput_id AND p.usage_day = s.d
  LEFT JOIN used u ON u.model_key = LOWER(k.model_name) AND u.usage_day = s.d
),
a AS (
  SELECT provisioned_throughput_id,
         SUM(IFF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS cur_credits,
         SUM(IFF(d < DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS prev_credits,
         COUNT_IF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND credits > 0) AS paid_days,
         COUNT_IF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND credits > 0 AND NOT model_used) AS idle_days,
         SUM(IFF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND NOT model_used, credits, 0)) AS idle_credits
  FROM spine
  GROUP BY provisioned_throughput_id
),
s AS (
  SELECT k.model_name || ' (' || k.provisioned_throughput_id || ')' AS throughput_name, k.model_name,
         k.ptu_count, k.term_end_date, DATEDIFF(day, __AS_OF_DATE__, k.term_end_date) AS days_to_term_end,
         a.cur_credits, a.prev_credits, a.paid_days, a.idle_days, a.idle_credits,
         100 * a.idle_days / NULLIF(a.paid_days, 0) AS idle_day_pct,
         100 * (a.cur_credits - a.prev_credits) / NULLIF(a.prev_credits, 0) AS change_pct,
         a.idle_credits * __AI_CREDIT_PRICE__ AS idle_usd
  FROM a JOIN keys k ON k.provisioned_throughput_id = a.provisioned_throughput_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, throughput_name, model_name, ptu_count,
       term_end_date, days_to_term_end, paid_days, idle_days, idle_day_pct,
       cur_credits AS current_credits, prev_credits AS previous_credits, change_pct, idle_credits,
       cur_credits * __AI_CREDIT_PRICE__ AS est_current_usd_list,
       prev_credits * __AI_CREDIT_PRICE__ AS est_previous_usd_list,
       idle_credits * __AI_CREDIT_PRICE__ AS est_idle_usd_list,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN idle_usd < :min_idle_usd THEN 'OK'
         WHEN idle_day_pct >= :crit_idle_pct THEN 'CRITICAL'
         WHEN idle_day_pct >= :warn_idle_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY est_idle_usd_list DESC NULLS LAST, current_credits DESC
