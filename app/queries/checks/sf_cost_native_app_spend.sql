-- query_id: sf_cost_native_app_spend
-- title: Installed Native Apps: credits and storage each app consumes
-- domain: cost   tier: standard
-- entity: native apps = app_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :crit_spend_usd (default 1000) spend usd: at or above this the row reads CRITICAL
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one installed Native App x service type for its credits, plus a '(storage)' row per app.
--   active_days_pct = share of the window's days the service used credits (always-on services sit near
--   100). current = the window, previous = the window before.
-- healthy: status = OK when an app's spend is small or flat.
-- investigate_if: WARN when a row spending >= min_spend_usd is new or grew >= warn_increase_pct;
--   CRITICAL when it grew >= crit_increase_pct, or spends >= crit_spend_usd and grew at all.
-- actions: 1) open the app in Snowsight and find who installed it and what it runs (free);
--   2) suspend its warehouse or container pool if it is idle, remove apps nobody uses (config);
--   3) renegotiate the listing or drop the app if its cost outweighs its use (spend).
-- next: none
-- not_assessed_reasons: unpriced: no credit or storage price is available, so the row cannot be priced
-- caveats: the credits are already inside the account's metering totals, so this is a slice of spend, not
--   an addition to it. Each service type is priced from its own breakdown credits, never also from the
--   day's total credits. Listing fees charged by the app provider are not included. Storage is a monthly
--   figure, kept in its own column and never added to the credit cost. Lags about a day. An empty result
--   means no apps only when the view is readable.
WITH days AS (
  SELECT DATEADD(day, -(seq4() + 1), __AS_OF_DATE__) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
),
lines AS (
  SELECT a.application_id, a.application_name, a.usage_date,
         COALESCE(f.value:serviceType::VARCHAR, IFF(f.value IS NULL, '(no breakdown)', '(unnamed)')) AS service_type,
         IFF(f.value IS NULL, a.credits_used, f.value:credits::FLOAT) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY a,
       LATERAL FLATTEN(input => a.credits_used_breakdown, outer => TRUE) f
  WHERE a.usage_date >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND a.usage_date < __AS_OF_DATE__
),
daily AS (
  SELECT application_id, MAX(application_name) AS application_name, service_type, usage_date,
         SUM(credits) AS credits
  FROM lines
  GROUP BY application_id, service_type, usage_date
),
keys AS (
  SELECT application_id, MAX(application_name) AS application_name, service_type
  FROM daily
  GROUP BY application_id, service_type
),
spine AS (
  SELECT k.application_id, k.service_type, s.d, COALESCE(dl.credits, 0) AS credits
  FROM keys k
  CROSS JOIN (SELECT d FROM days WHERE d >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__)) s
  LEFT JOIN daily dl ON dl.application_id = k.application_id AND dl.service_type = k.service_type
                    AND dl.usage_date = s.d
),
c AS (
  SELECT application_id, service_type,
         SUM(IFF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS cur_credits,
         SUM(IFF(d < DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS prev_credits,
         COUNT_IF(d >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND credits > 0) AS active_days
  FROM spine
  GROUP BY application_id, service_type
),
credit_rows AS (
  SELECT k.application_name || ' (' || k.application_id || ')' AS app_name, k.service_type,
         c.cur_credits, c.prev_credits, c.active_days,
         100 * (c.cur_credits - c.prev_credits) / NULLIF(c.prev_credits, 0) AS change_pct
  FROM c JOIN keys k ON k.application_id = c.application_id AND k.service_type = c.service_type
),
st AS (
  SELECT application_id, MAX(application_name) AS application_name,
         AVG(storage_bytes) AS avg_storage_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY application_id
),
u AS (
  SELECT app_name, service_type, cur_credits, prev_credits, active_days, change_pct,
         CAST(NULL AS DOUBLE) AS avg_storage_bytes
  FROM credit_rows
  UNION ALL
  SELECT application_name || ' (' || application_id || ')', '(storage)', CAST(NULL AS DOUBLE),
         CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE), avg_storage_bytes
  FROM st
  WHERE avg_storage_bytes > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, app_name, service_type,
       cur_credits AS current_credits, prev_credits AS previous_credits, change_pct,
       100 * active_days / :period_days AS active_days_pct,
       avg_storage_bytes,
       cur_credits * __CREDIT_PRICE__ AS est_current_usd_list,
       prev_credits * __CREDIT_PRICE__ AS est_previous_usd_list,
       avg_storage_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS est_storage_usd_month,
       IFF(service_type = '(storage)', IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced'),
           IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced')) AS price_basis,
       CASE WHEN service_type = '(storage)' AND __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced'
            WHEN service_type <> '(storage)' AND __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN service_type = '(storage)' THEN IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'NOT_ASSESSED', 'OK')
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_credits * __CREDIT_PRICE__ < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN cur_credits * __CREDIT_PRICE__ >= :crit_spend_usd AND change_pct > 0 THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM u
ORDER BY current_credits DESC NULLS LAST, avg_storage_bytes DESC NULLS LAST
