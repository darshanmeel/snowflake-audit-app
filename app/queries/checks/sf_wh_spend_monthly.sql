-- query_id: sf_wh_spend_monthly
-- title: Warehouse spend per calendar month
-- domain: cost   tier: standard
-- entity: warehouses = warehouse_id
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- empty_if: role_cannot_see, no_activity
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Confirm that a month's warehouses add up to the
--   WAREHOUSE_METERING row of cost_monthly_actuals for the same month.
-- read_this: One row = one warehouse in one of the last 13 calendar months (UTC), the current one
--   included. credits_billed = compute credits plus cloud services after the daily 10% adjustment;
--   usd_list prices them at the effective $ per credit. A warehouse has a row for every month, so a month
--   it did not run reads 0, not missing; a month before the account's usage history starts has NULL
--   credits (no_history), never 0. is_partial_month is TRUE for the current month and for a month the
--   history starts partway through; partial_reason says which, and first_day and last_day give the days
--   it covers. A partial month is never scaled up (sf_cost_month_end_forecast is the forecast).
-- healthy: n/a - inventory (spend, not a verdict)
-- investigate_if: n/a - inventory; compare a warehouse's full months
-- actions: n/a - inventory, nothing to act on
-- next: cost_monthly_actuals
-- caveats: The cloud services adjustment is taken per day across the account and spread over the
--   warehouses by their cloud services credits. Months follow UTC. The price is one effective $ per
--   credit for all months, so a rate change mid-term is not in here (see sf_cost_rate_sheet).
--   ACCOUNT_USAGE lags up to 3 h (cloud services 6 h).
WITH cs AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(month, -12, DATE_TRUNC('month', __AS_OF_DATE__)) AND usage_date < __AS_OF_DATE__
  GROUP BY usage_date
),
-- Days the account has usage rows for, per month: whether a month is whole.
cover AS (
  SELECT DATE_TRUNC('month', usage_date) AS month_start, COUNT(DISTINCT usage_date) AS days_captured,
         MIN(usage_date) AS first_day, MAX(usage_date) AS last_day
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(month, -12, DATE_TRUNC('month', __AS_OF_DATE__)) AND usage_date < __AS_OF_DATE__
  GROUP BY 1
),
wh AS (
  SELECT TO_VARCHAR(w.warehouse_id) AS warehouse_id, DATE_TRUNC('month', w.start_time) AS month_start,
         MAX_BY(w.warehouse_name, w.start_time) AS warehouse_name,
         SUM(w.credits_used_compute) AS credits_compute,
         SUM(COALESCE(w.credits_used_cloud_services, 0) * COALESCE(r.billed_ratio, 1)) AS credits_cloud_services_billed
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
  LEFT JOIN cs r ON r.usage_date = DATE(w.start_time)
  WHERE w.start_time >= DATEADD(month, -12, DATE_TRUNC('month', __AS_OF_DATE__)) AND w.start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
names AS (
  SELECT warehouse_id, MAX_BY(warehouse_name, month_start) AS warehouse_name FROM wh GROUP BY 1
),
-- Every month for every warehouse, so a month with no usage reads 0 instead of dropping out.
spine AS (
  SELECT DATEADD(month, -k, DATE_TRUNC('month', __AS_OF_DATE__)) AS month_start
  FROM (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12)) v (k)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, n.warehouse_id, n.warehouse_name, s.month_start,
       IFF(c.days_captured IS NULL, NULL, COALESCE(w.credits_compute, 0)) AS credits_compute,
       IFF(c.days_captured IS NULL, NULL, COALESCE(w.credits_cloud_services_billed, 0)) AS credits_cloud_services_billed,
       IFF(c.days_captured IS NULL, NULL, COALESCE(w.credits_compute, 0) + COALESCE(w.credits_cloud_services_billed, 0)) AS credits_billed,
       IFF(c.days_captured IS NULL, NULL,
           (COALESCE(w.credits_compute, 0) + COALESCE(w.credits_cloud_services_billed, 0)) * __CREDIT_PRICE__) AS usd_list,
       c.days_captured, c.first_day, c.last_day,
       s.month_start = DATE_TRUNC('month', __AS_OF_DATE__)
         OR COALESCE(c.days_captured, 0) < DAY(LAST_DAY(s.month_start)) AS is_partial_month,
       CASE WHEN s.month_start = DATE_TRUNC('month', __AS_OF_DATE__) THEN 'month_in_progress'
            WHEN c.days_captured IS NULL THEN 'no_history'
            WHEN c.days_captured < DAY(LAST_DAY(s.month_start)) THEN 'history_starts_mid_month'
       END AS partial_reason,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis
FROM names n
CROSS JOIN spine s
LEFT JOIN wh w ON w.warehouse_id = n.warehouse_id AND w.month_start = s.month_start
LEFT JOIN cover c ON c.month_start = s.month_start
ORDER BY n.warehouse_id, s.month_start
