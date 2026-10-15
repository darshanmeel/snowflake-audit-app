-- query_id: sf_chg_by_warehouse_and_user_daily
-- title: Daily chargeback export by warehouse and user
-- domain: cost   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_day_usd (default 100) day usd: at or above this the row reads WARN; :crit_day_usd
--   (default 1000) day usd: at or above this the row reads CRITICAL; :warn_idle_day_usd (default 50)
--   idle day usd: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse x user x day, plus one '(warehouse idle)' row per warehouse-day,
--   so the rows of a warehouse-day add up to its metered compute credits (warehouse_day_credits).
--   attributed_credits are exact per-query compute credits (query acceleration is billed as its own
--   service and shown in query_acceleration_credits, outside the split; a query with no user reads
--   '(unknown user)');
--   share_of_warehouse_day_pct is the row's part of that day's warehouse compute. Meant to be exported
--   as is into a chargeback sheet.
-- healthy: status = OK when no user spends a lot on one warehouse in one day and idle stays small.
-- investigate_if: WARN when a user-day on a warehouse is >= warn_day_usd, or an idle row is >=
--   warn_idle_day_usd; CRITICAL when a user-day is >= crit_day_usd.
-- actions: 1) look at the query history of the user on that day for runaway or repeated jobs (free); 2)
--   put a resource monitor or statement timeout on the warehouse; lower auto-suspend where idle rows
--   repeat (config); 3) move the heavy user to a warehouse sized and charged for it (spend).
-- next: none
-- caveats: adaptive warehouses (no query-time split) and hours newer than the 8 h attribution lag are left out of both sides, so they never read as idle; queries under about 100 ms have no attribution row and fall into the idle row. Cloud
--   services and serverless credits are not in this split. Days are UTC. Attribution lags up to 8
--   hours.
WITH u AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         DATE(start_time) AS usage_date, COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)') AS user_name,
         COUNT(*) AS queries,
         COUNT(DISTINCT NULLIF(TRIM(query_tag), '')) AS distinct_query_tags,
         SUM(credits_attributed_compute) AS credits,
         SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP())
  GROUP BY TO_VARCHAR(warehouse_id), DATE(start_time), COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)')
),
w AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         DATE(start_time) AS usage_date, SUM(IFF(credits_attributed_compute_queries IS NOT NULL AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_used_compute, 0)) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), DATE(start_time)
),
rows_ AS (
  SELECT u.warehouse_id, COALESCE(w.warehouse_name, u.warehouse_name) AS warehouse_name, u.usage_date,
         u.user_name, IFF(u.user_name = '(unknown user)', 'unknown_user', 'user') AS row_kind, u.queries,
         u.distinct_query_tags, u.credits, u.qas_credits, w.compute_credits
  FROM u
  LEFT JOIN w ON w.warehouse_id = u.warehouse_id AND w.usage_date = u.usage_date
  UNION ALL
  SELECT w.warehouse_id, w.warehouse_name, w.usage_date, '(warehouse idle)', 'idle', NULL, NULL,
         GREATEST(w.compute_credits - COALESCE(x.credits, 0), 0), NULL, w.compute_credits
  FROM w
  LEFT JOIN (SELECT warehouse_id, usage_date, SUM(credits) AS credits FROM u GROUP BY 1, 2) x
    ON x.warehouse_id = w.warehouse_id AND x.usage_date = w.usage_date
  WHERE w.compute_credits > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date, warehouse_name,
       warehouse_id, user_name, row_kind, queries, distinct_query_tags,
       credits AS attributed_credits, qas_credits AS query_acceleration_credits,
       compute_credits AS warehouse_day_credits,
       100 * credits / NULLIF(compute_credits, 0) AS share_of_warehouse_day_pct,
       credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN row_kind = 'idle' AND credits * __CREDIT_PRICE__ >= :warn_idle_day_usd THEN 'WARN'
         WHEN row_kind IN ('user', 'unknown_user') AND credits * __CREDIT_PRICE__ >= :crit_day_usd THEN 'CRITICAL'
         WHEN row_kind IN ('user', 'unknown_user') AND credits * __CREDIT_PRICE__ >= :warn_day_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM rows_
ORDER BY usage_date, warehouse_name, attributed_credits DESC NULLS LAST
