-- query_id: sf_ai_cortex_search_stale_index_serving
-- title: Cortex Search services that bill serving while their index takes no new rows
-- domain: serving_ai   tier: standard
-- entity: search services = service_id
-- money: est_serving_usd_list
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :stale_days (default 7) days with serving billed and no embedding credits: at or above this the
--   service reads WARN; :crit_stale_days (default 21) days: at or above this it reads CRITICAL;
--   :min_serving_usd (default 25) serving usd in the window: least a row needs before it can flag
-- empty_if: view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the serving spend
--   cannot be priced
-- read_this: one row = one Cortex Search service that billed serving in the window. Serving bills per
--   GB-month of index while the service can answer, queried or not; embedding credits (EMBED_TEXT_TOKENS)
--   bill only when the index takes new or changed rows. days_without_new_rows counts the days since the
--   last embedding credits (looked for over twice the window); a service that serves every day and embeds
--   nothing has an index that stopped changing. Either its source is static, or indexing is suspended or
--   failing. serving_credits and est_serving_usd_list are its serving spend in the window: spend at risk
--   of serving stale results, never waste.
-- healthy: status = OK when the index took new rows within stale_days, or serving is small.
-- investigate_if: WARN when serving spend >= min_serving_usd and no embedding credits for stale_days or
--   more; CRITICAL at crit_stale_days or more.
-- actions: 1) run DESCRIBE CORTEX SEARCH SERVICE and read INDEXING_STATE and INDEXING_ERROR; fix the
--   source query or resume indexing (free); 2) if the source is static on purpose, lengthen TARGET_LAG so
--   refreshes stop waking the warehouse (config); 3) suspend serving on a service nobody queries (free)
-- next: sf_ai_cortex_search_spend
-- caveats: the account-wide views have no index state, error or data timestamp: those sit in each
--   database's INFORMATION_SCHEMA.CORTEX_SEARCH_SERVICES, which one statement cannot read for every
--   database. So staleness here is "no embedding credits", which a static source also shows. A refresh
--   that only deletes rows embeds nothing. Batch queries (CONSUMPTION_TYPE BATCH) are left out.
WITH d AS (
  SELECT service_id, database_name, schema_name, service_name, consumption_type, credits,
         DATE(usage_date) AS day
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
s AS (
  SELECT service_id,
         MAX_BY(database_name || '.' || schema_name || '.' || service_name, day) AS service_full_name,
         MAX_BY(service_name, day) AS service_name,
         SUM(IFF(consumption_type = 'SERVING' AND day >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS serving_credits,
         SUM(IFF(consumption_type = 'EMBED_TEXT_TOKENS' AND day >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits, 0)) AS embed_credits,
         COUNT(DISTINCT IFF(consumption_type = 'SERVING' AND credits > 0 AND day >= DATEADD(day, -:period_days, __AS_OF_DATE__), day, NULL)) AS serving_days,
         MAX(IFF(consumption_type = 'SERVING' AND credits > 0, day, NULL)) AS last_serving_day,
         MAX(IFF(consumption_type = 'EMBED_TEXT_TOKENS' AND credits > 0, day, NULL)) AS last_embed_day,
         MIN(day) AS first_seen_day
  FROM d
  GROUP BY service_id
),
f AS (
  SELECT s.*,
         -- no embedding at all in twice the window: count from the first day it was seen
         DATEDIFF(day, COALESCE(last_embed_day, DATEADD(day, -1, first_seen_day)), last_serving_day) AS days_without_new_rows,
         serving_credits * __AI_CREDIT_PRICE__ AS serving_usd
  FROM s
  WHERE serving_credits > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, service_id, service_full_name, service_name,
       serving_days, serving_credits, embed_credits, last_serving_day, last_embed_day, days_without_new_rows,
       serving_usd AS est_serving_usd_list,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN serving_usd < :min_serving_usd THEN 'OK'
         WHEN days_without_new_rows >= :crit_stale_days THEN 'CRITICAL'
         WHEN days_without_new_rows >= :stale_days THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY days_without_new_rows DESC, serving_credits DESC
