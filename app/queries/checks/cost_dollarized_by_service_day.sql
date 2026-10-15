-- query_id: cost_dollarized_by_service_day
-- title: Dollarized cost by service and day (list price)
-- domain: cost   tier: deep
-- entity: service-days = billing_origin_product, usage_date
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one day + cloud + service type + usage unit's usage, priced at the effective
--   list price. The columns that matter are net_usage_quantity (the native-unit volume) and
--   net_list_cost (usage_quantity x the effective list rate) - this is a pre-discount estimate, not
--   what you actually pay. price_basis (free/priced/unpriced) discloses whether net_list_cost is a
--   real $0 (a free-usage service) or understated by a pricing-coverage gap.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: sku_name holds the service type; credits billed at the effective
--   credit price.
WITH __INCLUDE_cost_lines__
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date, __CLOUD__ AS cloud,
       sku_name, billing_origin_product, usage_type, usage_unit, 'USD' AS currency_code,
       SUM(qty) AS net_usage_quantity,
       SUM(usd) AS net_list_cost,
       CASE WHEN MAX(rate) IS NOT NULL THEN 'priced' ELSE 'unpriced' END AS price_basis
FROM cost_lines
WHERE period = 'current'
GROUP BY usage_date, sku_name, billing_origin_product, usage_type, usage_unit
ORDER BY usage_date DESC, sku_name
