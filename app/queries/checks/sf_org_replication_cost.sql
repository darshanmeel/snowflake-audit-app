-- query_id: sf_org_replication_cost
-- title: Replication cost by account and database
-- domain: cost   tier: standard
-- money: est_cost
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.REPLICATION_USAGE_HISTORY,
--   SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :warn_amount (default 100)
--   amount: at or above this the row reads WARN; :crit_amount (default 1000) amount: at or above this
--   the row reads CRITICAL; :warn_growth_pct (default 50) growth pct: at or above this the row reads
--   WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one replicated database in the account that refreshes it (the secondary;
--   account = account locator). credits = replication compute credits; tb_transferred = bytes
--   copied. est_cost = credits x the account's billed replication rate (invoice amount / credits for
--   replication usage types) in the invoice currency; est_cost_usd_list uses the audit price. Transfer
--   charges for the bytes appear in sf_org_data_transfer_by_account.
-- healthy: status = OK when a database's replication costs under warn_amount or is flat.
-- investigate_if: WARN when it costs >= warn_amount and grew >= warn_growth_pct or is new; CRITICAL
--   when it costs >= crit_amount.
-- actions: 1) check that the secondary is still needed for DR or reads (free); 2) refresh less often,
--   replicate only the databases that need it, move churny staging tables out (config); 3) replace
--   copies for read-only consumers with Secure Data Sharing (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. The view covers database replication; replication-group refreshes
--   show under the group's databases. Lags up to 24 hours. If the priced rate is missing, est_cost
--   falls back to NULL and only est_cost_usd_list is shown.
WITH r AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(region) AS region,
         database_name,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(usage_date < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits_used, 0)) AS prev_credits,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred)), 0)) / POWER(1024, 4) AS tb_transferred
  FROM SNOWFLAKE.ORGANIZATION_USAGE.REPLICATION_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator, database_name
),
rate AS (
  SELECT account_locator, MAX(currency) AS currency,
         SUM(usage_in_currency) / NULLIF(SUM(usage), 0) AS replication_rate
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_type ILIKE '%replication%' AND usage_type NOT ILIKE '%transfer%'
    AND usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
s AS (
  SELECT r.*, rate.currency, rate.replication_rate,
         credits * rate.replication_rate AS est_cost,
         prev_credits * rate.replication_rate AS prev_est_cost,
         100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         COALESCE(credits * rate.replication_rate, credits * __CREDIT_PRICE__) AS cost_for_status
  FROM r LEFT JOIN rate ON rate.account_locator = r.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       region, database_name, credits, prev_credits, change_pct, tb_transferred,
       currency, replication_rate, est_cost, prev_est_cost,
       credits * __CREDIT_PRICE__ AS est_cost_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN cost_for_status IS NULL THEN 'unpriced'
            WHEN credits = 0 THEN 'no_credits_in_window' END AS not_assessed_reason,
       CASE
         WHEN cost_for_status IS NULL OR credits = 0 THEN 'NOT_ASSESSED'
         WHEN cost_for_status >= :crit_amount THEN 'CRITICAL'
         WHEN cost_for_status >= :warn_amount AND (prev_credits = 0 OR change_pct >= :warn_growth_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY credits DESC
