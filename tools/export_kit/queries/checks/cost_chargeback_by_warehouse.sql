-- query_id: cost_chargeback_by_warehouse
-- title: Chargeback by warehouse, with change vs the previous period
-- domain: cost   tier: standard
-- money: usd_list
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_increase_pct (default 25) percent increase in list-priced spend, current period over
--   previous, at/above which WARN; :crit_increase_pct (default 50) percent increase at/above which
--   CRITICAL; :min_spend_usd (default 20) the current period's own list-priced spend must be at least
--   this before a percent change is judged; :top_n (default 20) how many status=OK, and separately how
--   many status=NOT_ASSESSED, warehouses ranked by current-period usd_list descending are kept as their
--   own row before the rest of that same status are pooled into their own is_other=true row - a real
--   finding (WARN/CRITICAL) is always kept as its own row, never pooled, so it can never be hidden
--   behind the cap. Needs 2x :period_days of billing history in the account for the previous-period
--   comparison
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one warehouse's spend in the selected window against the equal-length window
--   right before it, both at the effective list price, plus billed_hours (how many distinct hourly
--   billing buckets it billed something in) and queries/usd_per_1000_queries (a cost-per-query
--   efficiency figure, from QUERY_HISTORY). usd_list and prev_usd_list are the two totals;
--   change_usd_list and change_pct compare them. price_basis discloses pricing coverage across both
--   windows combined; not_assessed_reason explains a NOT_ASSESSED row. is_other=true marks up to
--   two pooled rows: one for every status=OK warehouse ranked below :top_n by current spend (reads
--   status OK), one for every status=NOT_ASSESSED warehouse ranked below :top_n (reads status
--   NOT_ASSESSED, not_assessed_reason NULL - the pooled rows can carry different reasons); either
--   is present only when pooled_count > 0 for that status (warehouse name and id NULL on both).
--   share_of_total_pct still adds up to ~100% across every row including these. Warehouse
--   name/type/size are not resolved here - join sf_wh_config_current on the warehouse.
-- healthy: status OK - no increase at/above :warn_increase_pct, or the row's own current-period spend
--   (a real $0 counts) sits below :min_spend_usd.
-- investigate_if: CRITICAL - the increase is at/above :crit_increase_pct on at least :min_spend_usd of
--   current spend, or brand-new spend above the floor with nothing in the previous period to compare
--   against. WARN - at/above :warn_increase_pct. NOT_ASSESSED - read not_assessed_reason:
--   'previous_window_not_covered' when the account's own earliest recorded usage does not reach back
--   far enough to cover the previous window at this window length; 'current_period_unpriced' /
--   'previous_period_unpriced' when that side's whole spend could not be priced at all. A row with
--   is_other=true is always OK or NOT_ASSESSED, never WARN/CRITICAL (see caveats).
-- actions: 1) open sf_wh_config_current for this warehouse to see its size, auto-stop and type
--   (free); 2) open sf_wh_idle_minutes for the same warehouse to see whether the spend increase
--   tracks more real query load or more idle running time (free); 3) if the growth is deliberate,
--   right-size or scale down the warehouse's config, or set a budget policy, before it compounds
--   another period (config, or spend if intentional).
-- next: none
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced; previous_window_not_covered: the account's earliest usage does not reach back over the whole
--   previous window, so there is nothing honest to compare with
-- caveats: Snowflake version: warehouse compute plus billed cloud services (the daily 10% adjustment is
--   taken off), current window vs the one before; status is judged per warehouse before the OK and
--   NOT_ASSESSED warehouses past :top_n fold into "other".
WITH -- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
wh AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), (credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1)), 0)) AS cur_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), (credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1)), 0)) AS prev_credits,
         COUNT_IF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND credits_used > 0) AS billed_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
q AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, COUNT(*) AS queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
  GROUP BY 1
),
cov AS (
  -- Earliest day with any warehouse usage: a young account has no honest previous window.
  SELECT MIN(CAST(start_time AS DATE)) AS first_usage_date
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__ AND credits_used > 0
),
scored AS (
  SELECT w.warehouse_id, w.billed_hours, COALESCE(q.queries, 0) AS queries, w.cur_credits,
         w.cur_credits * __CREDIT_PRICE__ AS usd, w.prev_credits * __CREDIT_PRICE__ AS prev_usd,
         CASE
           WHEN c.first_usage_date IS NULL OR c.first_usage_date > DATEADD(day, -2 * :period_days, __AS_OF_DATE__)
             THEN 'previous_window_not_covered'
           WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
         END AS reason
  FROM wh w LEFT JOIN q ON q.warehouse_id = w.warehouse_id CROSS JOIN cov c
),
judged AS (
  SELECT s.*,
         CASE
           WHEN reason IS NOT NULL THEN 'NOT_ASSESSED'
           WHEN GREATEST(usd, prev_usd) < :min_spend_usd THEN 'OK'
           WHEN prev_usd = 0 THEN 'WARN'
           WHEN 100 * (usd - prev_usd) / prev_usd >= :crit_increase_pct THEN 'CRITICAL'
           WHEN 100 * (usd - prev_usd) / prev_usd >= :warn_increase_pct THEN 'WARN'
           ELSE 'OK'
         END AS st
  FROM scored s
),
ranked AS (
  SELECT j.*, ROW_NUMBER() OVER (PARTITION BY st ORDER BY cur_credits DESC) AS rn
  FROM judged j
),
-- Status is judged per warehouse first; only OK and NOT_ASSESSED rows past :top_n are pooled.
keyed AS (
  SELECT r.*, IFF(rn <= :top_n OR st IN ('WARN', 'CRITICAL'), warehouse_id, 'other') AS grp_key
  FROM ranked r
),
-- Group on plain columns only: Snowflake rejects a derived flag that wraps the window column.
folded AS (
  SELECT grp_key AS warehouse_id, grp_key = 'other' AS is_other, st,
         COUNT(*) AS pooled_count, SUM(billed_hours) AS billed_hours, SUM(queries) AS queries,
         SUM(usd) AS usd, SUM(prev_usd) AS prev_usd,
         IFF(grp_key = 'other', NULL, MAX(reason)) AS reason
  FROM keyed
  GROUP BY grp_key, st
),
total AS (SELECT SUM(usd) AS usd FROM folded)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, f.warehouse_id, f.is_other,
       f.pooled_count, f.billed_hours, f.queries,
       IFF(f.queries > 0, 1000 * f.usd / f.queries, NULL) AS usd_per_1000_queries,
       f.usd AS usd_list, 100 * f.usd / NULLIF(t.usd, 0) AS share_of_total_pct,
       f.prev_usd AS prev_usd_list, f.usd - f.prev_usd AS change_usd_list,
       IFF(f.prev_usd > 0, 100 * (f.usd - f.prev_usd) / f.prev_usd, NULL) AS change_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       f.st AS status,
       f.reason AS not_assessed_reason
FROM folded f CROSS JOIN total t
ORDER BY f.is_other, f.usd DESC
