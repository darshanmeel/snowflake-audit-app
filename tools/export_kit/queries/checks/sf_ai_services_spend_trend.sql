-- query_id: sf_ai_services_spend_trend
-- title: AI and container spend, share of the bill and growth
-- domain: serving_ai   tier: standard
-- entity: AI services = service_type
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 50) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :warn_share_pct (default 15) share pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one AI-related service type (AI_SERVICES covers Cortex functions, search,
--   analyst and document AI; SNOWPARK_CONTAINER_SERVICES covers compute pools). current = the window,
--   previous = the window before; share_of_bill_pct is its part of all billed credits in the window.
-- healthy: status = OK when AI spend is small, flat, or a small part of the bill.
-- investigate_if: WARN when a service spending >= min_spend_usd is new, grew >= warn_increase_pct, or
--   is >= warn_share_pct of the bill; CRITICAL when it grew >= crit_increase_pct.
-- actions: 1) open sf_ai_functions_spend_by_user, sf_ai_cortex_search_spend, sf_ai_cortex_analyst_spend
--   and sf_ai_snowpark_container_services for who and what (free); 2) set a budget or monitor for AI
--   use, choose smaller models, suspend idle services (config); 3) agree an AI budget line with finance
--   before it grows further (spend).
-- next: none
-- caveats: service type names follow METERING_DAILY_HISTORY, with AI_INFERENCE (the name live accounts
--   bill under) reported as AI_SERVICES; AI service types (AI, CORTEX, COCO, COWORK in the name) are
--   priced at the AI credit price, the rest at the credit price.
WITH raw AS (
  SELECT usage_date, service_type,
         IFF(service_type IN ('AI_SERVICES', 'AI_INFERENCE'), 'AI_SERVICES', service_type) AS report_type,
         SUM(credits_billed) AS credits_billed
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY usage_date, service_type
),
-- live accounts bill AI as AI_INFERENCE, the docs say AI_SERVICES: one row, the larger per day so a day under both is not counted twice
d AS (
  SELECT usage_date, report_type AS service_type,
         IFF(report_type = 'AI_SERVICES', MAX(credits_billed), SUM(credits_billed)) AS credits_billed
  FROM raw
  GROUP BY usage_date, report_type
),
m AS (
  SELECT service_type,
         SUM(IFF(usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_billed, 0)) AS cur_credits,
         SUM(IFF(usage_date < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_billed, 0)) AS prev_credits
  FROM d
  GROUP BY service_type
),
p AS (
  -- AI credits have their own price
  SELECT m.*, IFF(REGEXP_LIKE(service_type, '(^|.*_)(AI|CORTEX|COCO|COWORK)(_.*|$)'),
                  __AI_CREDIT_PRICE__, __CREDIT_PRICE__) AS rate
  FROM m
),
s AS (
  SELECT p.*,
         100 * cur_credits / NULLIF(SUM(cur_credits) OVER (), 0) AS share_pct,
         100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         cur_credits * rate AS cur_usd
  FROM p
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, service_type,
       cur_credits AS current_credits, prev_credits AS previous_credits,
       cur_credits - prev_credits AS change_credits, change_pct, share_pct AS share_of_bill_pct,
       cur_credits * rate AS est_current_usd_list,
       prev_credits * rate AS est_previous_usd_list,
       IFF(rate IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN rate IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN rate IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_usd < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct OR share_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
-- explicit list: a name match on AI would also pick up Fail-safe recovery and others
WHERE service_type IN ('AI_SERVICES', 'SNOWPARK_CONTAINER_SERVICES')
ORDER BY est_current_usd_list DESC NULLS LAST, current_credits DESC
