-- query_id: sf_ai_credits_on_failed_queries
-- title: Cortex AI credits spent on queries that failed, timed out or were cancelled
-- domain: serving_ai   tier: standard
-- entity: AI callers = user_name, function_name, model_name, warehouse_name
-- money: est_wasted_usd_list
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 10) failed usd: at or above this the row reads WARN; :crit_usd (default 100)
--   failed usd: at or above this the row reads CRITICAL; :min_failed_pct (default 2) failed pct of the
--   row's AI credits: least a row needs before it can flag
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the failed credits
--   cannot be priced
-- read_this: one row = one user x warehouse x AI function x model with AI credits on statements that did
--   not succeed. Cortex bills the tokens it processed even when the statement fails or is cancelled
--   later. failed_credits splits into cancelled (error 604), timed_out (error 630) and error (any other
--   code; top_error_code is the commonest). failed_pct is the share of the row's AI credits in the window.
--   Warehouse time of the same statements is in cost_failed_statement_waste, never added here.
-- healthy: status = OK when little AI spend is lost to failed statements.
-- investigate_if: WARN when failed credits cost >= warn_usd and are >= min_failed_pct of the row's AI
--   spend; CRITICAL at crit_usd.
-- actions: 1) for errors, test the prompt and output parsing on a sample before the full table, and use
--   TRY_ variants or TRY_CAST around the AI output (free); 2) for timeouts and cancels, process the table
--   in batches with a filter on rows not yet done, so a rerun does not pay for the same tokens (free);
--   3) set a statement timeout on the warehouse that matches the batch size (config)
-- next: sf_ai_functions_spend_by_user, cost_failed_statement_waste
-- caveats: QUERY_HISTORY is read for the AI statements only, over the window (a heavy view: pre-filtered
--   on the AI query ids). A statement QUERY_HISTORY does not list (other than SQL, or older than the
--   window) is left out. Usage rows of a running statement count once it ends. User and role are
--   recorded from 16 Feb 2026 only.
WITH ai AS (
  SELECT query_id, function_name, COALESCE(NULLIF(model_name, ''), '(none)') AS model_name, warehouse_id,
         user_id, credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
-- QUERY_HISTORY is heavy: only the window, only statements that did not succeed, only AI query ids.
qh AS (
  SELECT query_id, execution_status, error_code
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND execution_status IN ('FAIL', 'INCIDENT')
    AND query_id IN (SELECT DISTINCT query_id FROM ai)
),
wh AS (
  SELECT warehouse_id, MAX_BY(warehouse_name, start_time) AS warehouse_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY warehouse_id
),
j AS (
  SELECT ai.*, qh.query_id IS NOT NULL AS failed,
         CASE WHEN qh.query_id IS NULL THEN NULL
              WHEN qh.error_code = 604 THEN 'cancelled'
              WHEN qh.error_code = 630 THEN 'timed_out'
              ELSE 'error' END AS outcome,
         qh.error_code
  FROM ai
  LEFT JOIN qh ON qh.query_id = ai.query_id
),
g AS (
  SELECT user_id, warehouse_id, function_name, model_name,
         SUM(credits) AS ai_credits,
         SUM(IFF(failed, credits, 0)) AS failed_credits,
         SUM(IFF(outcome = 'cancelled', credits, 0)) AS cancelled_credits,
         SUM(IFF(outcome = 'timed_out', credits, 0)) AS timed_out_credits,
         SUM(IFF(outcome = 'error', credits, 0)) AS error_credits,
         COUNT(DISTINCT IFF(failed, query_id, NULL)) AS failed_queries,
         COUNT(DISTINCT query_id) AS ai_queries,
         MODE(IFF(outcome = 'error', error_code, NULL)) AS top_error_code,
         MAX_BY(IFF(failed, query_id, NULL), IFF(failed, credits, NULL)) AS costliest_failed_query_id
  FROM j
  GROUP BY user_id, warehouse_id, function_name, model_name
  HAVING SUM(IFF(failed, credits, 0)) > 0
),
n AS (
  SELECT g.*,
         COALESCE(u.name || ' (' || g.user_id || ')', IFF(g.user_id IS NULL, 'not recorded', 'unknown (' || g.user_id || ')')) AS user_name,
         COALESCE(w.warehouse_name || ' (' || g.warehouse_id || ')',
                  'unknown (' || COALESCE(TO_VARCHAR(g.warehouse_id), '?') || ')') AS warehouse_name,
         100 * failed_credits / NULLIF(ai_credits, 0) AS failed_pct,
         failed_credits * __AI_CREDIT_PRICE__ AS failed_usd
  FROM g
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.user_id = TRY_TO_NUMBER(TO_VARCHAR(g.user_id))
  LEFT JOIN wh w ON w.warehouse_id = g.warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, warehouse_id, warehouse_name,
       function_name, model_name, ai_queries, failed_queries, ai_credits, failed_credits, cancelled_credits,
       timed_out_credits, error_credits, failed_pct, top_error_code, costliest_failed_query_id,
       failed_usd AS est_wasted_usd_list,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN failed_pct < :min_failed_pct THEN 'OK'
         WHEN failed_usd >= :crit_usd THEN 'CRITICAL'
         WHEN failed_usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM n
ORDER BY failed_credits DESC
