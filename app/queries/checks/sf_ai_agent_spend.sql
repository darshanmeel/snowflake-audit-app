-- query_id: sf_ai_agent_spend
-- title: Cortex Agent spend by agent and user
-- domain: serving_ai   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :warn_share_pct (default 50) share pct: at or above this the row reads WARN
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one Cortex Agent x user. token_credits are what the agent's model calls cost and
--   are the only credits priced. sql_query_credits and ai_functions_credits are what the agent's own SQL
--   and AI-function calls cost; they are shown for context, not priced or added. current = the window,
--   previous = the window before.
-- healthy: status = OK when an agent's spend is small or flat.
-- investigate_if: WARN when a row spending >= min_spend_usd is new, grew >= warn_increase_pct, or makes
--   >= warn_share_pct of all agent spend; CRITICAL when it grew >= crit_increase_pct.
-- actions: 1) ask the agent's owner what drives the requests and who calls it (free); 2) pick a smaller
--   model, shorten the instructions and tool output, stop retry loops (config); 3) set an AI budget and
--   limit who can use the agent (spend).
-- next: sf_ai_spend_by_feature_reconciled
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced
-- caveats: the SQL credit fields lag up to 8 hours, so the last hours read low. ai_functions_credits
--   are AI-function credits the agent triggered and can also show in sf_ai_functions_spend_by_user, and
--   sql_query_credits are warehouse credits also in warehouse metering, so neither is added to
--   token_credits. Shares are of token credits.
WITH a AS (
  SELECT COALESCE(agent_database_name || '.' || agent_schema_name || '.' || agent_name, 'unknown')
           || ' (' || COALESCE(TO_VARCHAR(agent_id), '?') || ')' AS agent_name,
         COALESCE(user_name || ' (' || TO_VARCHAR(user_id) || ')', 'unknown (' || COALESCE(TO_VARCHAR(user_id), '?') || ')') AS user_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), token_credits, 0)) AS cur_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), token_credits, 0)) AS prev_credits,
         COUNT(DISTINCT IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), request_id, NULL)) AS cur_requests,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__),
                 TRY_TO_DOUBLE(TO_VARCHAR(metadata:sql_query_credits)), 0)) AS sql_query_credits,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__),
                 TRY_TO_DOUBLE(TO_VARCHAR(metadata:ai_functions_credits)), 0)) AS ai_functions_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
s AS (
  SELECT a.*, 100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * cur_credits / NULLIF(SUM(cur_credits) OVER (), 0) AS share_pct,
         cur_credits * __AI_CREDIT_PRICE__ AS cur_usd
  FROM a
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, agent_name, user_name,
       cur_requests AS current_requests, cur_credits AS current_credits, prev_credits AS previous_credits,
       change_pct, share_pct AS share_of_agent_pct, cur_credits / NULLIF(cur_requests, 0) AS credits_per_request,
       sql_query_credits, ai_functions_credits,
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
