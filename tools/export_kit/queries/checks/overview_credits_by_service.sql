-- query_id: overview_credits_by_service
-- title: Where the credits go - net credits by account and service type
-- domain: cost   tier: lite
-- entity: services = billing_origin_product
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account + service type's net credit usage over the window, after the
--   cloud-services adjustment.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: credits billed by service type.
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, service_type AS sku_name,
       service_type AS billing_origin_product, SUM(credits_billed) AS net_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
GROUP BY service_type
ORDER BY net_credits DESC
