-- query_id: sf_org_data_transfer_by_account
-- title: Data transfer by account: cross-region and cross-cloud bytes and cost
-- domain: cost   tier: standard
-- money: amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.DATA_TRANSFER_HISTORY,
--   SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :warn_amount (default 50)
--   amount: at or above this the row reads WARN; :crit_amount (default 500) amount: at or above this
--   the row reads CRITICAL; :warn_growth_pct (default 50) growth pct: at or above this the row reads
--   WARN; :warn_cross_cloud_pct (default 50) cross cloud pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account that moved data out of its region (account = account locator).
--   tb_cross_region = TB to another region of the same cloud; tb_cross_cloud = TB to another cloud or
--   the internet; top_transfer_type = the type (COPY, REPLICATION, EXTERNAL_ACCESS, ...) with the most
--   bytes. amount = data transfer billed in the invoice currency; prev_amount = the same-length period
--   before.
-- healthy: status = OK when transfer costs under warn_amount or is flat.
-- investigate_if: WARN when it costs >= warn_amount and grew >= warn_growth_pct, is new, or >=
--   warn_cross_cloud_pct of the bytes leave the cloud; CRITICAL when it costs >= crit_amount.
-- actions: 1) run sf_cost_data_transfer_egress in the account to find the route (free); 2) keep stages
--   and consumers in the same region, replicate less often, compress unloads (config); 3) move
--   consumers next to the data or use Secure Data Sharing instead of copies (spend).
-- next: none
-- caveats: the org view is daily (USAGE_DATE) and its bytes are a VARIANT, cast before summing. Needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. Same-region transfer is free and not listed. Accounts with an
--   invoice amount but no DATA_TRANSFER_HISTORY rows still appear, with NULL bytes.
WITH t AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(region) AS region,
         SUM(IFF(source_cloud = target_cloud, bytes_transferred, 0)) / POWER(1024, 4) AS tb_cross_region,
         SUM(IFF(source_cloud <> target_cloud OR target_cloud IS NULL, bytes_transferred, 0)) / POWER(1024, 4) AS tb_cross_cloud,
         SUM(bytes_transferred) / POWER(1024, 4) AS tb_total,
         COUNT(DISTINCT target_cloud || '/' || target_region) AS target_routes
  FROM (SELECT account_locator, account_name, region, usage_date, source_cloud, target_cloud, target_region,
               TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred)) AS bytes_transferred
        FROM SNOWFLAKE.ORGANIZATION_USAGE.DATA_TRANSFER_HISTORY)
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
tt AS (
  SELECT account_locator, MAX_BY(transfer_type, tb) AS top_transfer_type
  FROM (
    SELECT account_locator, transfer_type, SUM(TRY_TO_DOUBLE(TO_VARCHAR(bytes_transferred))) AS tb
    FROM SNOWFLAKE.ORGANIZATION_USAGE.DATA_TRANSFER_HISTORY
    WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
      AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
    GROUP BY account_locator, transfer_type
  )
  GROUP BY account_locator
),
c AS (
  SELECT account_locator, MAX(account_name) AS account_name, MAX(region) AS region,
         MAX(currency) AS currency,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), usage_in_currency, 0)) AS amount,
         SUM(IFF(usage_date < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), usage_in_currency, 0)) AS prev_amount,
         SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), usage, 0)) AS billed_tb
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_type ILIKE '%transfer%'
    AND usage_date >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator
),
s AS (
  SELECT COALESCE(t.account_locator, c.account_locator) AS account_locator,
         COALESCE(t.account_name, c.account_name) AS account_name,
         COALESCE(t.region, c.region) AS region,
         t.tb_cross_region, t.tb_cross_cloud, t.tb_total, t.target_routes, tt.top_transfer_type,
         c.billed_tb, c.currency, COALESCE(c.amount, 0) AS amount, COALESCE(c.prev_amount, 0) AS prev_amount,
         100 * t.tb_cross_cloud / NULLIF(t.tb_total, 0) AS cross_cloud_pct
  FROM t
  FULL OUTER JOIN c ON c.account_locator = t.account_locator
  LEFT JOIN tt ON tt.account_locator = t.account_locator
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       region, tb_total, tb_cross_region, tb_cross_cloud, cross_cloud_pct, target_routes,
       top_transfer_type, billed_tb, currency, amount, prev_amount,
       100 * (amount - prev_amount) / NULLIF(prev_amount, 0) AS change_pct,
       CASE WHEN COALESCE(tb_total, 0) = 0 AND amount = 0 THEN 'no_transfer_in_window' END AS not_assessed_reason,
       CASE
         WHEN COALESCE(tb_total, 0) = 0 AND amount = 0 THEN 'NOT_ASSESSED'
         WHEN amount >= :crit_amount THEN 'CRITICAL'
         WHEN amount < :warn_amount THEN 'OK'
         WHEN prev_amount = 0 OR 100 * (amount - prev_amount) / prev_amount >= :warn_growth_pct THEN 'WARN'
         WHEN cross_cloud_pct >= :warn_cross_cloud_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY amount DESC, tb_total DESC NULLS LAST
