-- query_id: overview_daily_credits_trend
-- title: Daily net-credit trend by account
-- domain: cost   tier: lite
-- entity: days = usage_date
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account + day's total net credit usage. Use this as the detail behind
--   the daily spend trend chart.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Credits billed per day, after the cloud-services adjustment.
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date,
       SUM(credits_billed) AS net_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
GROUP BY usage_date
ORDER BY usage_date
