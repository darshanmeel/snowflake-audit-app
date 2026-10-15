-- query_id: sf_ai_cortex_search_spend
-- title: Cortex Search service spend by service
-- domain: serving_ai   tier: standard
-- entity: search services = service_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :warn_serving_share_pct (default 80) serving share pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one Cortex Search service. serving_credits are charged for keeping the index
--   online (by index size, whether or not anyone queries it); other_credits are embedding and indexing
--   work when the source changes. current = the window, previous = the window before.
-- healthy: status = OK when a service's spend is small or flat.
-- investigate_if: WARN when a service spending >= min_spend_usd is new, grew >= warn_increase_pct, or
--   is >= warn_serving_share_pct serving (a large always-on index); CRITICAL when it grew >=
--   crit_increase_pct.
-- actions: 1) confirm each service still backs a live app (free); 2) ALTER CORTEX SEARCH SERVICE ...
--   SUSPEND SERVING on unused ones, index fewer columns and rows, lengthen TARGET_LAG so it re-embeds
--   less often (config); 3) drop services nobody uses (spend).
-- next: none
-- caveats: this view has no query counts, so an unused index shows only as steady serving spend. The
--   warehouse that refreshes the service is billed separately as normal compute.
WITH c AS (
  SELECT TO_VARCHAR(service_id) AS service_id,
         MAX(database_name || '.' || schema_name || '.' || service_name) AS service_name,
         SUM(IFF(usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS cur_credits,
         SUM(IFF(usage_date < DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS prev_credits,
         SUM(IFF(usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__)
                 AND consumption_type ILIKE '%serving%', credits, 0)) AS cur_serving_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY 1
),
s AS (
  SELECT c.*, 100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * cur_serving_credits / NULLIF(cur_credits, 0) AS serving_share_pct,
         cur_credits * __AI_CREDIT_PRICE__ AS cur_usd
  FROM c
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, service_name, service_id,
       cur_credits AS current_credits, cur_serving_credits AS serving_credits,
       cur_credits - cur_serving_credits AS other_credits, serving_share_pct,
       prev_credits AS previous_credits, change_pct,
       cur_credits * __AI_CREDIT_PRICE__ AS est_current_usd_list,
       prev_credits * __AI_CREDIT_PRICE__ AS est_previous_usd_list,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_usd < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct OR serving_share_pct >= :warn_serving_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY current_credits DESC
