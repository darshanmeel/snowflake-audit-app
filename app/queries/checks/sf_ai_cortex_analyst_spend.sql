-- query_id: sf_ai_cortex_analyst_spend
-- title: Cortex Analyst spend by user
-- domain: serving_ai   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :warn_share_pct (default 50) share pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user of Cortex Analyst (natural-language questions over a semantic model).
--   Analyst is billed per request, so credits track request_count; credits_per_request shows the unit
--   price. current = the window, previous = the window before.
-- healthy: status = OK when a user's spend is small or flat.
-- investigate_if: WARN when a user spending >= min_spend_usd is new, grew >= warn_increase_pct, or
--   makes >= warn_share_pct of all Analyst spend (often an app or script looping); CRITICAL when it
--   grew >= crit_increase_pct.
-- actions: 1) ask the top user or app owner what drives the requests (free); 2) cache answers to
--   repeated questions in the app, stop retries on failures (config); 3) set an AI budget and limit who
--   holds the CORTEX_USER role (spend).
-- next: none
-- caveats: the warehouse that runs the generated SQL is billed separately as normal compute.
WITH a AS (
  SELECT username AS user_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS cur_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS prev_credits,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), request_count, 0)) AS cur_requests
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
s AS (
  SELECT a.*, 100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * cur_credits / NULLIF(SUM(cur_credits) OVER (), 0) AS share_pct,
         cur_credits * __AI_CREDIT_PRICE__ AS cur_usd
  FROM a
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name,
       cur_requests AS current_requests, cur_credits AS current_credits,
       prev_credits AS previous_credits, change_pct, share_pct AS share_of_analyst_pct,
       cur_credits / NULLIF(cur_requests, 0) AS credits_per_request,
       cur_credits * __AI_CREDIT_PRICE__ AS est_current_usd_list,
       prev_credits * __AI_CREDIT_PRICE__ AS est_previous_usd_list,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_usd < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct OR share_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY current_credits DESC
