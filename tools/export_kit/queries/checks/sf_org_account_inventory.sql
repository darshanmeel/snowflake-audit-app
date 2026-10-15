-- query_id: sf_org_account_inventory
-- title: Accounts in the organization: edition, region and billing
-- domain: governance_access   tier: standard
-- money: amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS, SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :new_account_days (default 30)
--   new account days: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account the organization has or had (account = account locator). cloud
--   is taken from the region name (AWS_ / AZURE_ / GCP_). amount = billed in the window in the invoice
--   currency. is_org_admin marks accounts where ORGADMIN is enabled; deleted_on is set for dropped
--   accounts, which Snowflake keeps until the grace period ends.
-- healthy: status = OK for a live account with a known owner comment, or a deleted account that no
--   longer bills.
-- investigate_if: WARN when an account has no comment (no owner on record), was created in the last
--   new_account_days, or ORGADMIN is enabled on more than one account; CRITICAL when a deleted account
--   still billed in the window.
-- actions: 1) record an owner and purpose in each account's COMMENT (free); 2) keep ORGADMIN on one
--   account and drop test accounts nobody uses (config); 3) confirm with Snowflake that deleted
--   accounts stop billing, e.g. storage kept through the grace period (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE database roles; without access this
--   check fails. deleted_on and is_org_admin are only present on recent versions of the view. Reader
--   (managed) accounts are billed to their provider and are counted in managed_accounts.
WITH a AS (
  SELECT account_locator, account_name, edition, region_group, region AS snowflake_region, created_on,
         deleted_on, "COMMENT" AS account_comment, is_org_admin, managed_accounts, account_url
  FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
),
u AS (
  SELECT account_locator, MAX(currency) AS currency, SUM(usage_in_currency) AS amount,
         MAX(usage_date) AS last_usage_date
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < __AS_OF_DATE__
  GROUP BY account_locator
),
s AS (
  SELECT a.*, u.currency, u.amount AS amount, u.last_usage_date,
         SPLIT_PART(a.snowflake_region, '_', 1) AS cloud,
         COUNT_IF(a.is_org_admin AND a.deleted_on IS NULL) OVER () AS org_admin_accounts
  FROM a LEFT JOIN u ON u.account_locator = a.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       edition, cloud, snowflake_region, region_group, created_on, deleted_on, is_org_admin,
       org_admin_accounts, managed_accounts, account_comment, account_url, currency, amount, last_usage_date,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN deleted_on IS NOT NULL AND amount > 0 THEN 'CRITICAL'
         WHEN deleted_on IS NOT NULL THEN 'OK'
         WHEN is_org_admin AND org_admin_accounts > 1 THEN 'WARN'
         WHEN created_on >= DATEADD(day, -:new_account_days, __AS_OF_DATE__) THEN 'WARN'
         WHEN account_comment IS NULL OR TRIM(account_comment) = '' THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY deleted_on IS NULL, amount DESC NULLS LAST
