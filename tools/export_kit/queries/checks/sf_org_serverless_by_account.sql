-- query_id: sf_org_serverless_by_account
-- title: Serverless feature credits by account
-- domain: cost   tier: standard
-- money: est_cost
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY,
--   SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :warn_amount (default 100)
--   amount: at or above this the row reads WARN; :crit_amount (default 1000) amount: at or above this
--   the row reads CRITICAL; :warn_growth_pct (default 50) growth pct: at or above this the row reads
--   WARN; :warn_share_pct (default 30) share pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account x serverless service type (AUTO_CLUSTERING, MATERIALIZED_VIEW, PIPE,
--   SEARCH_OPTIMIZATION, QUERY_ACCELERATION, SERVERLESS_TASK, SNOWPIPE_STREAMING, AI_SERVICES, ...);
--   warehouse compute and cloud services are left out (account = account locator). credits =
--   credits billed; est_cost = credits x the account's average billed rate per credit in the invoice
--   currency; share_of_account_pct = share of all credits the account billed.
-- healthy: status = OK when a feature costs under warn_amount or is flat.
-- investigate_if: WARN when it costs >= warn_amount and grew >= warn_growth_pct, is new, or is >=
--   warn_share_pct of the account's credits; CRITICAL when it costs >= crit_amount.
-- actions: 1) run the matching check in that account (sf_storage_clustering_value,
--   sf_storage_mv_value, sf_pipe_cost_and_files, sf_storage_search_optimization_value,
--   sf_wh_query_acceleration_spend, sf_task_cost) (free); 2) drop clustering keys, MVs or search
--   optimization that nobody reads, batch pipe loads (config); 3) move steady serverless work to a
--   right-sized warehouse (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. Serverless rates per credit differ by service; est_cost uses the
--   account's average credit rate, so sf_org_spend_by_account_and_service holds the exact billed amount
--   per usage type.
WITH raw AS (
  SELECT account_locator, MAX(account_name) AS account_name, usage_date, service_type,
         IFF(service_type IN ('AI_SERVICES', 'AI_INFERENCE'), 'AI_SERVICES', service_type) AS report_type,
         SUM(credits_billed) AS credits_billed
  FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator, usage_date, service_type
),
-- live accounts bill AI as AI_INFERENCE, the docs say AI_SERVICES: one row, the larger per day so a day under both is not counted twice
d AS (
  SELECT account_locator, MAX(account_name) AS account_name, usage_date, report_type AS service_type,
         IFF(report_type = 'AI_SERVICES', MAX(credits_billed), SUM(credits_billed)) AS credits_billed
  FROM raw
  GROUP BY account_locator, usage_date, report_type
),
m AS (
  SELECT account_locator, MAX(account_name) AS account_name, service_type,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits_billed, 0)) AS credits,
         SUM(IFF(usage_date < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits_billed, 0)) AS prev_credits
  FROM d
  GROUP BY account_locator, service_type
),
tot AS (
  SELECT m.*, SUM(credits) OVER (PARTITION BY account_locator) AS account_credits
  FROM m
),
rate AS (
  SELECT account_locator, MAX(currency) AS currency,
         SUM(usage_in_currency) / NULLIF(SUM(usage), 0) AS credit_rate
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE NOT (usage_type ILIKE '%storage%' OR usage_type ILIKE '%transfer%')
    AND usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
s AS (
  SELECT tot.*, rate.currency, rate.credit_rate,
         credits * rate.credit_rate AS est_cost,
         100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * credits / NULLIF(account_credits, 0) AS share_of_account_pct,
         COALESCE(credits * rate.credit_rate, credits * __CREDIT_PRICE__) AS cost_for_status
  FROM tot LEFT JOIN rate ON rate.account_locator = tot.account_locator
  WHERE service_type NOT IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER', 'CLOUD_SERVICES')
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       service_type, credits, prev_credits, change_pct, share_of_account_pct, currency, credit_rate,
       est_cost, credits * __CREDIT_PRICE__ AS est_cost_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN credits = 0 AND prev_credits = 0 THEN 'no_credits'
            WHEN cost_for_status IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN (credits = 0 AND prev_credits = 0) OR cost_for_status IS NULL THEN 'NOT_ASSESSED'
         WHEN cost_for_status >= :crit_amount THEN 'CRITICAL'
         WHEN cost_for_status < :warn_amount THEN 'OK'
         WHEN prev_credits = 0 OR change_pct >= :warn_growth_pct THEN 'WARN'
         WHEN share_of_account_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY cost_for_status DESC NULLS LAST
