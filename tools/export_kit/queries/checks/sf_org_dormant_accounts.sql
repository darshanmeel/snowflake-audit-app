-- query_id: sf_org_dormant_accounts
-- title: Dormant accounts that still bill (storage with little or no compute)
-- domain: cost   tier: standard
-- money: amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS, SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY,
--   SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY,
--   SNOWFLAKE.ORGANIZATION_USAGE.STORAGE_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :dormant_credits (default 1)
--   dormant credits: value this check uses; :warn_amount (default 50) amount: at or above this the row
--   reads WARN; :crit_amount (default 500) amount: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live account whose compute credits in the window are under dormant_credits
--   (account = account locator). compute_credits = warehouse credits; all_credits = every metered
--   service; amount = billed in the invoice currency (mostly storage for a dormant account);
--   avg_storage_tb = average bytes held on the last day seen. last_compute_date = last day with any
--   warehouse credits in the window.
-- healthy: status = OK when a dormant account costs less than warn_amount.
-- investigate_if: WARN when a dormant account bills >= warn_amount in the window; CRITICAL when it
--   bills >= crit_amount.
-- actions: 1) ask the account's owner whether it is still needed (free); 2) drop old databases and
--   stages, shorten time travel, or replicate what matters to a live account (config); 3) drop the
--   account (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. Compute is only a proxy for use: an account can serve data shares
--   or reader accounts with no warehouse credits of its own. For logins per account see
--   sf_org_login_activity_by_account. Lags up to 72 hours.
WITH acct AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(edition) AS edition,
         MAX(region) AS snowflake_region, MAX(created_on) AS created_on
  FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
  WHERE deleted_on IS NULL
  GROUP BY account_locator
),
m AS (
  SELECT account_locator,
         SUM(IFF(service_type = 'WAREHOUSE_METERING', credits_used, 0)) AS compute_credits,
         SUM(credits_used) AS all_credits,
         MAX(IFF(service_type = 'WAREHOUSE_METERING' AND credits_used > 0, usage_date, NULL)) AS last_compute_date
  FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
c AS (
  SELECT account_locator, MAX(currency) AS currency, SUM(usage_in_currency) AS amount,
         SUM(IFF(usage_type ILIKE '%storage%', usage_in_currency, 0)) AS storage_amount
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
st AS (
  SELECT account_locator, MAX_BY(bytes, usage_date) / POWER(1024, 4) AS avg_storage_tb
  FROM (
    SELECT account_locator, usage_date, SUM(average_bytes) AS bytes
    FROM SNOWFLAKE.ORGANIZATION_USAGE.STORAGE_DAILY_HISTORY
    WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
      AND usage_date < __AS_OF_DATE__
    GROUP BY account_locator, usage_date
  )
  GROUP BY account_locator
),
s AS (
  SELECT acct.*, COALESCE(m.compute_credits, 0) AS compute_credits,
         COALESCE(m.all_credits, 0) AS all_credits, m.last_compute_date,
         c.currency, COALESCE(c.amount, 0) AS amount, COALESCE(c.storage_amount, 0) AS storage_amount,
         st.avg_storage_tb
  FROM acct
  LEFT JOIN m ON m.account_locator = acct.account_locator
  LEFT JOIN c ON c.account_locator = acct.account_locator
  LEFT JOIN st ON st.account_locator = acct.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       edition, snowflake_region, created_on, compute_credits, all_credits, last_compute_date,
       avg_storage_tb, currency, amount, storage_amount,
       CASE WHEN created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) THEN 'created_in_window' END AS not_assessed_reason,
       CASE
         WHEN created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) THEN 'NOT_ASSESSED'
         WHEN amount >= :crit_amount THEN 'CRITICAL'
         WHEN amount >= :warn_amount THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
WHERE compute_credits < :dormant_credits
ORDER BY amount DESC
