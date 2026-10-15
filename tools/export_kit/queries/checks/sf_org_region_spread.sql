-- query_id: sf_org_region_spread
-- title: Accounts, spend and transfer per cloud region
-- domain: cost   tier: standard
-- money: amount
-- entity: regions = cloud, region
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS, SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY,
--   SNOWFLAKE.ORGANIZATION_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :warn_transfer_share_pct
--   (default 10) transfer share pct: at or above this the row reads WARN; :crit_transfer_share_pct
--   (default 30) transfer share pct: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one Snowflake region the organization has live accounts in or bills in. cloud
--   comes from the region name. amount = billed in the invoice currency; transfer_amount = the data
--   transfer part of it. tb_out_same_cloud / tb_out_other_cloud = TB its accounts sent to other regions
--   of the same cloud or to other clouds; top_target = the destination with the most bytes.
-- healthy: status = OK when data transfer is a small share of the region's bill.
-- investigate_if: WARN when transfer is >= warn_transfer_share_pct of the region's amount; CRITICAL at
--   >= crit_transfer_share_pct.
-- actions: 1) list which accounts and jobs move data between these regions
--   (sf_org_data_transfer_by_account) (free); 2) keep producers and consumers in one region, or share
--   instead of copy (config); 3) consolidate small regional accounts into the main region where
--   residency rules allow (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. Some regions exist for data residency or DR on purpose; the spread
--   alone is not a problem.
WITH a AS (
  SELECT region, COUNT(*) AS live_accounts,
         LISTAGG(DISTINCT edition, ', ') WITHIN GROUP (ORDER BY edition) AS editions
  FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
  WHERE deleted_on IS NULL
  GROUP BY region
),
c AS (
  SELECT region, MAX(currency) AS currency, SUM(usage_in_currency) AS amount,
         SUM(IFF(usage_type ILIKE '%transfer%', usage_in_currency, 0)) AS transfer_amount,
         COUNT(DISTINCT account_locator) AS billing_accounts
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY region
),
routes AS (
  SELECT region, target_cloud || '/' || target_region AS target,
         SUM(IFF(source_cloud = target_cloud, bytes, 0)) AS same_cloud_bytes,
         SUM(IFF(source_cloud = target_cloud, 0, bytes)) AS other_cloud_bytes
  -- The org view is daily (USAGE_DATE) and BYTES_TRANSFERRED is a VARIANT, cast before summing.
  FROM (SELECT region, usage_date, source_cloud, target_cloud, target_region,
               TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred)) AS bytes
        FROM SNOWFLAKE.ORGANIZATION_USAGE.DATA_TRANSFER_HISTORY)
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY 1, 2
),
t AS (
  SELECT region,
         SUM(same_cloud_bytes) / POWER(1024, 4) AS tb_out_same_cloud,
         SUM(other_cloud_bytes) / POWER(1024, 4) AS tb_out_other_cloud,
         MAX_BY(target, same_cloud_bytes + other_cloud_bytes) AS top_target,
         COUNT(DISTINCT target) AS targets
  FROM routes
  GROUP BY region
),
s AS (
  SELECT COALESCE(a.region, c.region) AS region, COALESCE(a.live_accounts, 0) AS live_accounts,
         a.editions, c.billing_accounts, c.currency, c.amount AS amount,
         COALESCE(c.transfer_amount, 0) AS transfer_amount,
         t.tb_out_same_cloud, t.tb_out_other_cloud, t.top_target, t.targets
  FROM a
  FULL OUTER JOIN c ON UPPER(c.region) = UPPER(a.region)
  LEFT JOIN t ON UPPER(t.region) = UPPER(COALESCE(a.region, c.region))
),
f AS (
  SELECT s.*, SPLIT_PART(region, '_', 1) AS cloud,
         100 * amount / NULLIF(SUM(amount) OVER (), 0) AS share_of_org_pct,
         100 * transfer_amount / NULLIF(amount, 0) AS transfer_share_pct
  FROM s
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, cloud, region, live_accounts,
       billing_accounts, editions, currency, amount, share_of_org_pct, transfer_amount,
       transfer_share_pct, tb_out_same_cloud, tb_out_other_cloud, targets, top_target,
       CASE WHEN COALESCE(amount, 0) = 0 THEN 'no_billed_usage' END AS not_assessed_reason,
       CASE
         WHEN COALESCE(amount, 0) = 0 THEN 'NOT_ASSESSED'
         WHEN transfer_share_pct >= :crit_transfer_share_pct THEN 'CRITICAL'
         WHEN transfer_share_pct >= :warn_transfer_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY amount DESC NULLS LAST
