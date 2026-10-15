-- query_id: sf_ai_functions_spend_by_user
-- title: Cortex AI function spend by user, role, warehouse and function
-- domain: serving_ai   tier: standard
-- entity: users = user_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :warn_query_usd (default 50) query usd: a single query at or above this reads WARN;
--   :crit_spend_usd (default 1000) spend usd: at or above this the row reads CRITICAL
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user x primary role x warehouse x AI function x model. Credits are the AI
--   function's own credits, billed apart from the warehouse that ran the query. max_query_credits is the
--   costliest single query (its hourly rows added up first); costliest_query_id names it. current = the
--   window, previous = the window before. User and role are recorded from 16 Feb 2026 only.
-- healthy: status = OK when a row's spend is small or flat and no single query is expensive.
-- investigate_if: WARN when a row spending >= min_spend_usd is new or grew >= warn_increase_pct, or one
--   query alone cost >= warn_query_usd; CRITICAL when it grew >= crit_increase_pct, or spends >=
--   crit_spend_usd and grew at all.
-- actions: 1) open the costliest query id in Snowsight query history and check it does not re-process
--   the same rows (free); 2) move to a smaller model where quality allows, trim prompts, cache results in
--   a table (config); 3) set a budget on AI use and restrict the CORTEX_USER role (spend).
-- next: sf_ai_spend_by_feature_reconciled
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced
-- caveats: replaces the check on the old CORTEX_FUNCTIONS view, which Snowflake no longer updates; never
--   add the two. A query running over several hours has one row per hour, so query counts and
--   max_query_credits are worked out per query id. A query using two functions shows once per function.
--   Warehouse compute of the same queries is billed separately and not added. Rows before 16 Feb 2026
--   read 'not recorded before 16 Feb 2026' for user and role. Priced at the AI credit price.
WITH wh AS (
  SELECT warehouse_id, MAX_BY(warehouse_name, start_time) AS warehouse_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY warehouse_id
),
b AS (
  SELECT f.query_id, f.function_name, COALESCE(NULLIF(f.model_name, ''), '(none)') AS model_name,
         f.warehouse_id, f.query_tag, f.credits, f.user_id, f.start_time,
         f.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AS is_cur,
         f.role_names[0]::VARCHAR AS role_raw,
         TRY_TO_NUMBER(TO_VARCHAR(f.user_id)) AS user_num
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY f
  WHERE f.start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND f.start_time < __AS_OF_DATE__
),
d AS (
  SELECT b.query_id, b.function_name, b.model_name, b.query_tag, b.credits, b.is_cur,
         CASE WHEN b.user_id IS NULL AND b.start_time < DATE '2026-02-16' THEN 'not recorded before 16 Feb 2026'
              WHEN u.name IS NOT NULL THEN u.name || ' (' || b.user_id || ')'
              ELSE 'unknown (' || COALESCE(TO_VARCHAR(b.user_id), '?') || ')' END AS user_name,
         CASE WHEN b.role_raw IS NULL AND b.start_time < DATE '2026-02-16' THEN 'not recorded before 16 Feb 2026'
              ELSE COALESCE(b.role_raw, 'unknown') END AS role_name,
         COALESCE(w.warehouse_name || ' (' || b.warehouse_id || ')',
                  'unknown (' || COALESCE(TO_VARCHAR(b.warehouse_id), '?') || ')') AS warehouse_name
  FROM b
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.user_id = b.user_num
  LEFT JOIN wh w ON w.warehouse_id = b.warehouse_id
),
q AS (
  SELECT user_name, role_name, warehouse_name, function_name, model_name, query_id,
         MAX(query_tag) AS query_tag,
         SUM(IFF(is_cur, credits, 0)) AS q_cur,
         SUM(IFF(is_cur, 0, credits)) AS q_prev
  FROM d
  GROUP BY user_name, role_name, warehouse_name, function_name, model_name, query_id
),
g AS (
  SELECT user_name, role_name, warehouse_name, function_name, model_name,
         SUM(q_cur) AS cur_credits, SUM(q_prev) AS prev_credits,
         COUNT(DISTINCT IFF(q_cur > 0, query_id, NULL)) AS queries,
         MAX(q_cur) AS max_query_credits,
         MAX_BY(query_id, q_cur) AS costliest_query_id,
         MAX_BY(query_tag, q_cur) AS costliest_query_tag
  FROM q
  GROUP BY user_name, role_name, warehouse_name, function_name, model_name
),
s AS (
  SELECT g.*, 100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * cur_credits / NULLIF(SUM(cur_credits) OVER (), 0) AS share_of_ai_functions_pct,
         cur_credits * __AI_CREDIT_PRICE__ AS cur_usd,
         max_query_credits * __AI_CREDIT_PRICE__ AS max_query_usd
  FROM g
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, role_name, warehouse_name,
       function_name, model_name, queries AS current_queries,
       cur_credits AS current_credits, prev_credits AS previous_credits, change_pct,
       share_of_ai_functions_pct, max_query_credits, costliest_query_id, costliest_query_tag,
       cur_credits * __AI_CREDIT_PRICE__ AS est_current_usd_list,
       prev_credits * __AI_CREDIT_PRICE__ AS est_previous_usd_list,
       max_query_credits * __AI_CREDIT_PRICE__ AS est_max_query_usd_list,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_usd < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN cur_usd >= :crit_spend_usd AND change_pct > 0 THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct OR max_query_usd >= :warn_query_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY current_credits DESC
