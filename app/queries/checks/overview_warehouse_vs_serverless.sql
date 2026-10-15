-- query_id: overview_warehouse_vs_serverless
-- title: Warehouse vs serverless split - net credits and shares by account
-- domain: cost   tier: lite
-- entity: accounts = account_id
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account's net credit split between virtual warehouses and serverless
--   services, with the serverless share. Use it to see how much of the bill is serverless.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: "classic" = user-managed virtual warehouses (WAREHOUSE_METERING and its reader variant);
--   "serverless" = every Snowflake-managed service (tasks, Snowpipe, clustering, MVs, search
--   optimization, AI, ...).
WITH m AS (
  SELECT SUM(IFF(service_type IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER'), 0, credits_billed)) AS serverless,
         SUM(IFF(service_type IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER'), credits_billed, 0)) AS classic,
         SUM(credits_billed) AS total
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       serverless AS serverless_net_credits, classic AS classic_net_credits,
       100 * serverless / NULLIF(total, 0) AS serverless_pct,
       total AS total_net_credits
FROM m
