-- query_id: overview_spend_estimate
-- title: Estimated net spend - net credits x credit price by account
-- domain: cost   tier: lite
-- entity: accounts = account_id
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account's total net credit usage and list-price dollar estimate over the
--   window. Use the currency_code to multiply by any FX rate or discount factor. price_basis
--   (free/priced/unpriced) discloses whether net_list_cost_usd mixes free-usage services (a real
--   $0) or is understated by a pricing-coverage gap.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: The credit total is credits billed. The dollar total adds storage (hybrid included; archive tiers are unpriced) and estimated data transfer.
WITH __INCLUDE_cost_lines__
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       SUM(IFF(usage_unit = 'CREDITS', qty, 0)) AS total_net_credits, 'USD' AS currency_code,
       SUM(usd) AS net_list_cost_usd,
       'effective credit price' AS credit_price_source,
       IFF(COUNT_IF(rate IS NULL) > 0, 'unpriced', 'priced') AS price_basis
FROM cost_lines
WHERE period = 'current'
