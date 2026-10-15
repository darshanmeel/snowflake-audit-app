-- query_id: sf_org_spend_by_account
-- title: Organization spend by account vs the previous period
-- domain: cost   tier: standard
-- money: amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY, SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :min_amount (default 100)
--   amount: least a row needs before it can flag; :warn_growth_pct (default 25) growth pct: at or above
--   this the row reads WARN; :crit_growth_pct (default 100) growth pct: at or above this the row reads
--   CRITICAL; :warn_share_pct (default 50) share pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account in the organization (account = account locator). amount is what
--   Snowflake billed that account in the window, in the contract currency (USAGE_IN_CURRENCY_DAILY, all
--   usage types, adjustments included); prev_amount is the same-length period before it;
--   share_of_org_pct is the account's share of the organization total. credits = consumption usage of
--   compute-rated types only (not storage or transfer TB, rebates or support); credit_amount is what
--   those credits cost and amount_per_credit = credit_amount / credits.
-- healthy: status = OK when the account's spend is flat or small.
-- investigate_if: WARN when spend grew >= warn_growth_pct, is new, or one account holds >=
--   warn_share_pct of the org (only for accounts above min_amount); CRITICAL when it grew >=
--   crit_growth_pct.
-- actions: 1) open sf_org_spend_by_account_and_service for the account that grew and find the service
--   behind it (free); 2) put resource monitors and budgets on the growing account (config); 3) move or
--   retire workloads in accounts whose spend has no owner (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles (run
--   it from the organization account); without access this check fails. The org views lag up to 72
--   hours, so the last settle_days are left out of both periods. Amounts are in the invoice currency,
--   not list USD; with several currencies share_of_org_pct is per currency.
WITH u AS (
  SELECT account_locator, account_name, region, currency, usage_type, usage_date,
         usage_in_currency, usage,
         -- rating type says what the quantity is; the legacy usage_type text is only a fallback
         COALESCE(LOWER(rating_type) = 'compute',
                  NOT (usage_type ILIKE '%storage%' OR usage_type ILIKE '%transfer%'))
           AND LOWER(COALESCE(billing_type, 'consumption')) = 'consumption' AS is_credit
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
),
agg AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(region) AS region, currency,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), usage_in_currency, 0)) AS amount,
         SUM(IFF(usage_date < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), usage_in_currency, 0)) AS prev_amount,
         -- only credit-rated consumption feeds the $/credit rate (storage, transfer, rebates, support do not)
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__) AND is_credit,
                 usage, 0)) AS credits,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__) AND is_credit,
                 usage_in_currency, 0)) AS credit_amount,
         MAX(usage_date) AS last_usage_date
  FROM u
  GROUP BY account_locator, currency
),
acct AS (
  SELECT account_locator, MAX(edition) AS edition, MAX(created_on) AS created_on
  FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
  GROUP BY account_locator
),
s AS (
  SELECT agg.*, acct.edition, acct.created_on,
         amount - prev_amount AS change_amount,
         100 * (amount - prev_amount) / NULLIF(prev_amount, 0) AS change_pct,
         100 * amount / NULLIF(SUM(amount) OVER (PARTITION BY currency), 0) AS share_of_org_pct,
         COUNT(*) OVER () AS accounts_in_org
  FROM agg LEFT JOIN acct ON acct.account_locator = agg.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       region, edition, created_on, currency, amount, prev_amount, change_amount, change_pct,
       share_of_org_pct, credits, credit_amount,
       credit_amount / NULLIF(credits, 0) AS amount_per_credit, last_usage_date,
       accounts_in_org,
       CASE WHEN amount = 0 AND prev_amount = 0 THEN 'no_billed_usage' END AS not_assessed_reason,
       CASE
         WHEN amount = 0 AND prev_amount = 0 THEN 'NOT_ASSESSED'
         WHEN amount < :min_amount THEN 'OK'
         WHEN change_pct >= :crit_growth_pct THEN 'CRITICAL'
         WHEN prev_amount = 0 OR change_pct >= :warn_growth_pct THEN 'WARN'
         WHEN share_of_org_pct >= :warn_share_pct AND accounts_in_org > 1 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY amount DESC
