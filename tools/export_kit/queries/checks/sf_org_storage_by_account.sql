-- query_id: sf_org_storage_by_account
-- title: Storage by account: size, growth and billed amount
-- domain: storage   tier: standard
-- money: storage_amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.STORAGE_DAILY_HISTORY,
--   SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :min_tb (default 1) tb: least a
--   row needs before it can flag; :warn_growth_pct (default 20) growth pct: at or above this the row
--   reads WARN; :crit_growth_pct (default 50) growth pct: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account x storage service type (table storage, hybrid table storage, ...)
--   (account = account locator). start_tb / end_tb = average bytes on the first and last day of
--   the window; growth_pct = change between them. storage_amount = storage billed in the invoice
--   currency for the account (rows rated per TB of storage, shown once, on the account's first row);
--   est_storage_usd_list = TB-days stored in the window x the audit's storage price per TB-month /
--   30.4 days.
-- healthy: status = OK when storage is small or grows slower than warn_growth_pct per window.
-- investigate_if: WARN when an account above min_tb grew >= warn_growth_pct; CRITICAL at >=
--   crit_growth_pct.
-- actions: 1) run sf_storage_growth_by_database and sf_storage_time_travel_heavy in the account (free);
--   2) drop unused tables and clones, shorten retention, use transient tables for staging (config); 3)
--   move cold data to external or Iceberg tables in cheaper storage (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. STORAGE_DAILY_HISTORY holds database + stage + fail-safe bytes
--   together; for the fail-safe split run sf_storage_failsafe_on_staging in the account.
WITH d AS (
  SELECT account_locator, MAX(account_name) AS account_name, service_type, usage_date,
         SUM(average_bytes) AS bytes
  FROM SNOWFLAKE.ORGANIZATION_USAGE.STORAGE_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator, service_type, usage_date
),
agg AS (
  SELECT account_locator, MAX(account_name) AS account_name, service_type,
         MIN(usage_date) AS first_date, MAX(usage_date) AS last_date,
         MIN_BY(bytes, usage_date) / POWER(1024, 4) AS start_tb,
         MAX_BY(bytes, usage_date) / POWER(1024, 4) AS end_tb,
         AVG(bytes) / POWER(1024, 4) AS avg_tb,
         SUM(bytes) / POWER(1024, 4) AS tb_days
  FROM d
  GROUP BY account_locator, service_type
),
c AS (
  SELECT account_locator, MAX(currency) AS currency, SUM(usage_in_currency) AS storage_amount
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  -- rating_type 'storage' is billed per TB; usage_type is legacy and also names credit-rated services
  WHERE (LOWER(rating_type) = 'storage' OR (rating_type IS NULL AND usage_type ILIKE '%storage%'))
    AND usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
s AS (
  SELECT agg.*, c.currency, c.storage_amount,
         end_tb - start_tb AS growth_tb,
         100 * (end_tb - start_tb) / NULLIF(start_tb, 0) AS growth_pct,
         100 * avg_tb / NULLIF(SUM(avg_tb) OVER (), 0) AS share_of_org_pct
  FROM agg LEFT JOIN c ON c.account_locator = agg.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       service_type, first_date, last_date, start_tb, end_tb, avg_tb, growth_tb, growth_pct,
       share_of_org_pct, currency,
       -- the bill is per account; one row carries it so an account with two service types counts once
       IFF(ROW_NUMBER() OVER (PARTITION BY account_locator ORDER BY service_type) = 1,
           storage_amount, NULL) AS storage_amount,
       -- price TB-days with the export's 30.4-day month so days with no storage are not priced
       tb_days * __STORAGE_PRICE_TB_MONTH__ / 30.4 AS est_storage_usd_list,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN first_date = last_date THEN 'single_day_of_data' END AS not_assessed_reason,
       CASE
         WHEN first_date = last_date THEN 'NOT_ASSESSED'
         WHEN end_tb < :min_tb THEN 'OK'
         WHEN growth_pct >= :crit_growth_pct THEN 'CRITICAL'
         WHEN growth_pct >= :warn_growth_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY end_tb DESC
