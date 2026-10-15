-- query_id: sf_org_spend_by_account_and_service
-- title: Organization spend by account and service type
-- domain: cost   tier: standard
-- money: amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :min_amount (default 50) amount:
--   least a row needs before it can flag; :warn_growth_pct (default 50) growth pct: at or above this
--   the row reads WARN; :crit_growth_pct (default 200) growth pct: at or above this the row reads
--   CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account x usage type (compute, cloud services, storage, data transfer,
--   automatic clustering, serverless tasks, ...) with the service_type Snowflake bills it under. amount
--   is billed in the contract currency; usage_qty is credits, or TB for storage and transfer;
--   effective_rate = amount / usage_qty. share_of_account_pct = share of that account's bill.
-- healthy: status = OK when the line is small or flat against the previous period.
-- investigate_if: WARN when a line above min_amount grew >= warn_growth_pct or is new; CRITICAL when it
--   grew >= crit_growth_pct.
-- actions: 1) run the matching per-account check in that account (e.g. sf_cost_serverless_features,
--   sf_storage_clustering_value) to find the object (free); 2) tune or suspend the feature that
--   grew (config); 3) negotiate rates for the usage types that dominate the bill (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. Lags up to 72 hours (last settle_days left out). Amounts are in
--   the invoice currency, not list USD.
WITH agg AS (
  SELECT account_locator, MAX(account_name) AS account_name, usage_type,
         MAX(service_type) AS service_type, MAX(LOWER(rating_type)) AS rating_type, currency,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), usage_in_currency, 0)) AS amount,
         SUM(IFF(usage_date < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), usage_in_currency, 0)) AS prev_amount,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), usage, 0)) AS usage_qty,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__) AND is_adjustment, usage_in_currency, 0)) AS adjustment_amount
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator, usage_type, currency
),
s AS (
  SELECT agg.*,
         -- rating_type says what is billed per TB; usage_type is legacy and also names credit-rated services
         COALESCE(LOWER(rating_type) IN ('storage', 'data_transfer'),
                  usage_type ILIKE '%storage%' OR usage_type ILIKE '%transfer%') AS per_tb,
         amount / NULLIF(usage_qty, 0) AS effective_rate,
         100 * (amount - prev_amount) / NULLIF(prev_amount, 0) AS change_pct,
         100 * amount / NULLIF(SUM(amount) OVER (PARTITION BY account_locator, currency), 0) AS share_of_account_pct
  FROM agg
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       usage_type, service_type, currency, usage_qty, IFF(per_tb, 'TB', 'credits') AS usage_unit,
       amount, prev_amount, amount - prev_amount AS change_amount, change_pct, effective_rate,
       adjustment_amount, share_of_account_pct,
       CASE WHEN amount = 0 AND prev_amount = 0 THEN 'no_billed_usage' END AS not_assessed_reason,
       CASE
         WHEN amount = 0 AND prev_amount = 0 THEN 'NOT_ASSESSED'
         WHEN amount < :min_amount THEN 'OK'
         WHEN change_pct >= :crit_growth_pct THEN 'CRITICAL'
         WHEN prev_amount = 0 OR change_pct >= :warn_growth_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY amount DESC
