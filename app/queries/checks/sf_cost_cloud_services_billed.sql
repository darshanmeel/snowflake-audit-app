-- query_id: sf_cost_cloud_services_billed
-- title: Cloud services billed above the 10% free allowance
-- domain: cost   tier: standard
-- money: est_billed_cloud_services_usd_list
-- entity: days = usage_date
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_daily_billed_usd (default 5) daily billed usd: at or above this the row reads WARN;
--   :crit_daily_billed_usd (default 50) daily billed usd: at or above this the row reads CRITICAL;
--   :warn_ratio_pct (default 10) ratio pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one day. cloud_services_credits is what cloud services used; the free allowance
--   is 10% of that day's compute credits (adjustment_credits, shown positive);
--   billed_cloud_services_credits is the part above it that is on the invoice. cloud_services_ratio_pct
--   = cloud services / compute; above 10 means you pay for it. allowance_result says how the day
--   came out: all free (within the 10%), part billed (above it), all billed (no adjustment that day)
--   or no cloud services; free_cloud_services_credits is the part the adjustment covered.
-- healthy: status = OK when cloud services stay within 10% of compute, so nothing is billed.
-- investigate_if: WARN when a day bills >= warn_daily_billed_usd of cloud services, or the ratio is >=
--   warn_ratio_pct with any billed amount; CRITICAL when a day bills >= crit_daily_billed_usd.
-- actions: 1) open sf_cost_cloud_services_drivers to see which warehouse, user and query type drive it
--   (free); 2) cut metadata-heavy work: frequent SHOW/DESCRIBE, tiny single-row INSERTs, COPY over huge
--   file lists, complex queries recompiled every run (config); 3) batch small statements into fewer,
--   larger ones (spend).
-- next: none
-- caveats: the allowance is computed per day for the whole account, not per warehouse; serverless and
--   AI credits are not part of the compute base (ratio denominator = the day's WAREHOUSE_METERING compute). ACCOUNT_USAGE lags up to 3 h, so the last day may be
--   incomplete.
WITH d AS (
  SELECT usage_date,
         -- the 10% allowance is read against the day's virtual warehouse compute only, not serverless
         SUM(IFF(service_type = 'WAREHOUSE_METERING', credits_used_compute, 0)) AS compute_credits,
         SUM(credits_used_cloud_services) AS cloud_services_credits,
         -SUM(credits_adjustment_cloud_services) AS adjustment_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY usage_date
),
s AS (
  SELECT d.*,
         GREATEST(cloud_services_credits - adjustment_credits, 0) AS billed_cs_credits,
         100 * cloud_services_credits / NULLIF(compute_credits, 0) AS ratio_pct
  FROM d
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date,
       compute_credits, cloud_services_credits, adjustment_credits,
       LEAST(cloud_services_credits, adjustment_credits) AS free_cloud_services_credits,
       billed_cs_credits AS billed_cloud_services_credits,
       CASE
         WHEN COALESCE(cloud_services_credits, 0) <= 0 THEN 'no cloud services'
         WHEN billed_cs_credits <= 0 THEN 'all free (within 10%)'
         WHEN COALESCE(adjustment_credits, 0) <= 0 THEN 'all billed (no adjustment)'
         ELSE 'part billed (above 10%)'
       END AS allowance_result,
       ratio_pct AS cloud_services_ratio_pct,
       billed_cs_credits * __CREDIT_PRICE__ AS est_billed_cloud_services_usd_list,
       SUM(billed_cs_credits) OVER () * __CREDIT_PRICE__ AS est_window_billed_cloud_services_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN billed_cs_credits * __CREDIT_PRICE__ >= :crit_daily_billed_usd THEN 'CRITICAL'
         WHEN billed_cs_credits * __CREDIT_PRICE__ >= :warn_daily_billed_usd THEN 'WARN'
         WHEN billed_cs_credits > 0 AND ratio_pct >= :warn_ratio_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY usage_date DESC
