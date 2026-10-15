-- query_id: sf_ai_cowork_spend
-- title: Snowflake CoWork spend per CoWork and user, against the window before
-- domain: serving_ai   tier: standard
-- entity: users = snowflake_cowork_name, user_name
-- windowed: yes
-- money: est_current_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COWORK_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :warn_share_pct (default 50) share pct: at or above this the row reads WARN
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The docs name no METERING_DAILY_HISTORY service type for
--   CoWork, so this is not tied to the bill.
-- read_this: one row = one user of one CoWork. requests are message requests, credits the token credits
--   Snowflake charges for them (agent calls and the Cortex Agents or Analyst work under them). current = the
--   window, previous = the window before. share_of_cowork_pct is the user's part of that CoWork's credits.
-- healthy: status = OK when a user's spend is small or flat.
-- investigate_if: WARN when a user spending >= min_spend_usd is new, grew >= warn_increase_pct, or makes
--   >= warn_share_pct of a CoWork; CRITICAL when it grew >= crit_increase_pct.
-- actions: 1) ask the top users what they use CoWork for and whether it is worth it (free); 2) point the
--   agents at smaller models or narrower tools (config); 3) set an AI budget for the CoWork users (spend).
-- next: sf_ai_agent_spend
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced
-- caveats: CoWork requests are not in CORTEX_AGENT_USAGE_HISTORY, so this is not counted twice with the
--   agent check; never add it to the metered AI total either. Warehouse credits of SQL the agents run are
--   in the warehouse's own spend. The view lags up to 1 hour. Message text is never read.
WITH w AS (
  SELECT COALESCE(snowflake_cowork_name, '(unnamed)') || ' (' || COALESCE(TO_VARCHAR(snowflake_cowork_id), '?') || ')'
           AS snowflake_cowork_name,
         COALESCE(user_name, 'unknown') || ' (' || COALESCE(TO_VARCHAR(user_id), '?') || ')' AS user_name,
         COUNT(DISTINCT IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), request_id, NULL)) AS requests,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), tokens, 0)) AS current_tokens,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), token_credits, 0)) AS cur_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), token_credits, 0)) AS prev_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COWORK_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
r AS (
  SELECT w.*,
         100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * cur_credits / NULLIF(SUM(cur_credits) OVER (PARTITION BY snowflake_cowork_name), 0) AS share_pct
  FROM w
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, snowflake_cowork_name, user_name, requests,
       current_tokens, cur_credits AS current_credits, prev_credits AS previous_credits, change_pct,
       share_pct AS share_of_cowork_pct,
       cur_credits * __AI_CREDIT_PRICE__ AS est_current_usd_list,
       prev_credits * __AI_CREDIT_PRICE__ AS est_previous_usd_list,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', NULL) AS not_assessed_reason,
       CASE
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_credits * __AI_CREDIT_PRICE__ < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct OR share_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM r
ORDER BY current_credits DESC
