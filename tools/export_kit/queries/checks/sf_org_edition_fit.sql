-- query_id: sf_org_edition_fit
-- title: Edition fit per account (heuristic)
-- domain: cost   tier: standard
-- money: amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS, SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY,
--   SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :min_amount (default 500)
--   amount: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live account (account = account locator). HEURISTIC: only features that
--   leave a metered trace are seen. enterprise_feature_credits = credits of MATERIALIZED_VIEW,
--   SEARCH_OPTIMIZATION and QUERY_ACCELERATION (Enterprise and above); replication_credits = any
--   REPLICATION credits (failover groups need Business Critical). compute_rate = billed amount per
--   compute credit, which is what the edition changes. fit says: 'possible_downgrade' when a higher
--   edition shows none of its metered features, else 'fits'.
-- healthy: status = OK when the account uses a metered feature of its edition, or costs little.
-- investigate_if: WARN when an Enterprise or Business Critical account billing >= min_amount shows none
--   of the metered features of that edition.
-- actions: 1) ask the owner which edition features the account relies on: multi-cluster warehouses,
--   time travel over 1 day, masking and row policies, Tri-Secret Secure, PrivateLink, compliance
--   (free); 2) move test or sandbox workloads to a Standard account (config); 3) change the edition
--   with Snowflake at renewal (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. Heuristic: multi-cluster warehouses, extended time travel, masking
--   and row access policies, Tri-Secret Secure, PrivateLink and compliance needs leave no trace in
--   these views, so a WARN is a question for the owner, never a finding by itself.
WITH acct AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(edition) AS edition,
         MAX(region) AS snowflake_region
  FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
  WHERE deleted_on IS NULL
  GROUP BY account_locator
),
m AS (
  SELECT account_locator,
         SUM(IFF(service_type IN ('MATERIALIZED_VIEW', 'SEARCH_OPTIMIZATION', 'QUERY_ACCELERATION'), credits_used, 0)) AS enterprise_feature_credits,
         SUM(IFF(service_type ILIKE '%REPLICATION%', credits_used, 0)) AS replication_credits,
         SUM(credits_used) AS all_credits
  FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
c AS (
  SELECT account_locator, MAX(currency) AS currency, SUM(usage_in_currency) AS amount,
         SUM(IFF(usage_type ILIKE 'compute', usage_in_currency, 0))
           / NULLIF(SUM(IFF(usage_type ILIKE 'compute', usage, 0)), 0) AS compute_rate
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
s AS (
  SELECT acct.*, COALESCE(m.enterprise_feature_credits, 0) AS enterprise_feature_credits,
         COALESCE(m.replication_credits, 0) AS replication_credits, COALESCE(m.all_credits, 0) AS all_credits,
         c.currency, c.amount AS amount, c.compute_rate,
         CASE
           WHEN UPPER(acct.edition) = 'BUSINESS_CRITICAL' AND COALESCE(m.replication_credits, 0) = 0
                AND COALESCE(m.enterprise_feature_credits, 0) = 0 THEN 'possible_downgrade_to_standard'
           WHEN UPPER(acct.edition) = 'BUSINESS_CRITICAL' AND COALESCE(m.replication_credits, 0) = 0 THEN 'possible_downgrade_to_enterprise'
           WHEN UPPER(acct.edition) = 'ENTERPRISE' AND COALESCE(m.enterprise_feature_credits, 0) = 0 THEN 'possible_downgrade_to_standard'
           ELSE 'fits'
         END AS fit
  FROM acct
  LEFT JOIN m ON m.account_locator = acct.account_locator
  LEFT JOIN c ON c.account_locator = acct.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       edition, snowflake_region, all_credits, enterprise_feature_credits, replication_credits,
       currency, amount, compute_rate, fit, 'heuristic' AS confidence,
       CASE WHEN edition IS NULL THEN 'edition_unknown'
            WHEN all_credits = 0 THEN 'no_usage_in_window' END AS not_assessed_reason,
       CASE
         WHEN edition IS NULL OR all_credits = 0 THEN 'NOT_ASSESSED'
         WHEN fit <> 'fits' AND amount >= :min_amount THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY status = 'WARN' DESC, amount DESC NULLS LAST
