-- query_id: cost_by_hour_of_day
-- title: When you spend - list-priced dollars by weekday x hour-of-day x service, with task runs
--   and queries running in the same slot
-- domain: cost   tier: standard
-- money: usd_list
-- entity: hour-of-day slots = weekday_num, hour_of_day
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the
--   export date; :warn_hour_share_pct (default 15) percent of the window's whole list-priced spend
--   one hour-of-day holds, summed across every weekday and service, at/above which that hour-of-day
--   flags WARN; :crit_hour_share_pct (default 25) the same at/above which it flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one account + weekday + hour-of-day + service slot's list-priced spend in
--   the window (UTC - see caveats). task runs (job_runs_active) and queries_started count activity
--   in that same weekday + hour-of-day slot ONCE and are repeated on every service row of that slot
--   (they have no service dimension of their own - see caveats). share_of_window_spend (0 to 100, percent) and
--   status describe the HOUR-OF-DAY alone (hour_usd_list is that hour's total, repeated on its weekday rows), collapsed across every weekday and service: what share of the
--   account's whole window spend lands in that one hour, whichever day it falls on - the peak-hour
--   signal a heat map is built from.
-- healthy: status = OK - this hour-of-day holds under :warn_hour_share_pct of the account's window
--   spend - field heuristic, both thresholds are header params.
-- investigate_if: status = WARN or CRITICAL - this hour-of-day holds at/above :warn_hour_share_pct or
--   :crit_hour_share_pct of the account's window spend, concentrated in one hour of the day across the
--   whole window.
-- actions: 1) Snowflake's own prices do not change by hour of day - the saving here comes from
--   avoiding PEAKS, not from a cheaper hour: fewer warehouse scale-outs and queued queries during
--   the spike, fewer clusters on shared warehouses sized for a flatter load, tasks and loads not
--   all starting at the same hour, 2am for example. Every figure on this row is measured from what
--   already happened, not a forecast (free); 2) if job_runs_active is high in the flagged hour,
--   stagger task schedules (cron offsets) across the day instead of a single top-of-hour trigger
--   (config); 3) if queries_started is high in the flagged hour on a warehouse-backed workload,
--   check query_warehouse_pressure and sf_wh_multicluster_scaling for that same hour - a spend peak
--   that is also a queuing/scale-out peak is worth smoothing first (config).
-- next: none
-- caveats: Snowflake version: warehouse compute plus billed cloud services by UTC weekday x hour (hour_timezone;
--   the export session is pinned to UTC, not to the account's own time zone); all 168 slots are listed, an hour
--   with no spend is a zero row, and each dollar is priced once. Flags an hour slot carrying a large share of spend.
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
slots AS (
  -- every weekday x hour slot, so an hour with no spend is a zero row and never a hole in the map
  SELECT d.weekday_num, d.weekday, h.hour_of_day
  FROM (VALUES (1, 'Mon'), (2, 'Tue'), (3, 'Wed'), (4, 'Thu'), (5, 'Fri'), (6, 'Sat'), (7, 'Sun')) AS d(weekday_num, weekday)
  CROSS JOIN (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12), (13), (14), (15), (16), (17), (18), (19), (20), (21), (22), (23)) AS h(hour_of_day)
),
spend AS (
  SELECT DAYOFWEEKISO(start_time) AS weekday_num, HOUR(start_time) AS hour_of_day,
         SUM((credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1))) * __CREDIT_PRICE__ AS usd
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
m AS (
  SELECT s.weekday, s.weekday_num, s.hour_of_day,
         IFF(__CREDIT_PRICE__ IS NULL, NULL, COALESCE(p.usd, 0)) AS usd
  FROM slots s LEFT JOIN spend p ON p.weekday_num = s.weekday_num AND p.hour_of_day = s.hour_of_day
),
qs AS (
  SELECT DAYOFWEEKISO(start_time) AS weekday_num, HOUR(start_time) AS hour_of_day, COUNT(*) AS n
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
ts AS (
  SELECT DAYOFWEEKISO(query_start_time) AS weekday_num, HOUR(query_start_time) AS hour_of_day, COUNT(*) AS n
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
total AS (SELECT SUM(usd) AS usd FROM m),
-- the flag is per hour-of-day (all weekdays and services together), not per weekday x hour slot
hod AS (SELECT hour_of_day, SUM(usd) AS usd FROM m GROUP BY 1)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, m.weekday, m.weekday_num,
       m.hour_of_day, 'UTC' AS hour_timezone, 'WAREHOUSE_METERING' AS billing_origin_product, m.usd AS usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       COALESCE(ts.n, 0) AS job_runs_active, COALESCE(qs.n, 0) AS queries_started,
       hd.usd AS hour_usd_list, t.usd AS window_usd_list,
       100 * hd.usd / NULLIF(t.usd, 0) AS share_of_window_spend,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', NULL) AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN 100 * hd.usd / NULLIF(t.usd, 0) >= :crit_hour_share_pct THEN 'CRITICAL'
         WHEN 100 * hd.usd / NULLIF(t.usd, 0) >= :warn_hour_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM m
CROSS JOIN total t
JOIN hod hd ON hd.hour_of_day = m.hour_of_day
LEFT JOIN qs ON qs.weekday_num = m.weekday_num AND qs.hour_of_day = m.hour_of_day
LEFT JOIN ts ON ts.weekday_num = m.weekday_num AND ts.hour_of_day = m.hour_of_day
ORDER BY m.weekday_num, m.hour_of_day
