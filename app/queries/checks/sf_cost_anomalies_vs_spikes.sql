-- query_id: sf_cost_anomalies_vs_spikes
-- title: Snowflake's own cost anomalies set against this audit's spend spikes, day by day
-- domain: cost   tier: standard
-- entity: days = usage_date
-- windowed: yes
-- money: est_change_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ANOMALIES_DAILY, SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :baseline_days (default 14) trailing days whose median is a day's baseline; :spike_ratio
--   (default 2.0) a day flags once it is at least this many times its baseline; :min_credits (default 20)
--   credits: a day needs at least this many before it can flag; :crit_credits (default 100) credits: a day
--   both sources flag and that is this far over expected reads CRITICAL
-- empty_if: view_missing, role_cannot_see, ingestion_lag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That the anomaly value and billed credits are the same
--   measure is not stated in the documentation.
-- read_this: one row = one day. snowflake_anomaly is Snowflake's flag with its expected range
--   (sf_upper_bound); our_spike is this audit's flag (a day at least :spike_ratio times the median of the
--   :baseline_days before it). agreement says whether both, one or neither flag it. est_change_usd_list is
--   the flagged day's credits above expected, priced once; it is a change, not spend or waste.
-- healthy: status = OK when neither source flags the day.
-- investigate_if: WARN when either source flags the day; CRITICAL when both flag it and it is at least
--   :crit_credits above expected.
-- actions: 1) open the day in the spend by service page and read what changed (free); 2) when only one source
--   flags it, trust Snowflake's range and check the audit's baseline for a step change (free); 3) add a
--   budget or anomaly notification for the service that drove it (config)
-- next: cost_daily_spikes
-- caveats: Snowflake needs 30 days of history and does not flag while the last 7 days total under 10
--   credits. Its view lags up to 8 hours, so the newest day can have no Snowflake row (snowflake_row is
--   FALSE). When the view holds several rows for a day, the flag is true if any is, and the widest bounds
--   are shown. Days with no usage are kept.
WITH days AS (
  SELECT DATEADD(day, -seq4() - 1, __AS_OF_DATE__) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
),
mine AS (
  SELECT usage_date, SUM(credits_billed) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -(:period_days + :baseline_days), __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY usage_date
),
daily AS (
  SELECT dd.d AS usage_date, COALESCE(m.credits, 0) AS credits
  FROM days dd
  LEFT JOIN mine m ON m.usage_date = dd.d
  WHERE dd.d >= DATEADD(day, -(:period_days + :baseline_days), __AS_OF_DATE__)
),
scored AS (
  SELECT a.usage_date, a.credits, MEDIAN(b.credits) AS baseline_credits
  FROM daily a
  LEFT JOIN daily b ON b.usage_date >= DATEADD(day, -:baseline_days, a.usage_date) AND b.usage_date < a.usage_date
  WHERE a.usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__)
  GROUP BY a.usage_date, a.credits
),
sf AS (
  SELECT an.date AS usage_date, BOOLOR_AGG(COALESCE(an.is_anomaly, FALSE)) AS is_anomaly, MAX(an.actual_value) AS actual_value,
         MAX(an.upper_bound) AS upper_bound, MIN(an.lower_bound) AS lower_bound, MAX(an.forecasted_value) AS forecasted_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.ANOMALIES_DAILY an
  WHERE an.date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND an.date < __AS_OF_DATE__
  GROUP BY an.date
),
j AS (
  SELECT c.usage_date, c.credits AS our_credits, c.baseline_credits AS our_baseline_credits,
         COALESCE(c.baseline_credits > 0 AND c.credits >= :spike_ratio * c.baseline_credits AND c.credits >= :min_credits, FALSE) AS our_spike,
         s.usage_date IS NOT NULL AS snowflake_row, COALESCE(s.is_anomaly, FALSE) AS snowflake_anomaly,
         s.actual_value AS sf_actual_credits, s.upper_bound AS sf_upper_bound, s.lower_bound AS sf_lower_bound,
         s.forecasted_value AS sf_forecast_credits
  FROM scored c
  LEFT JOIN sf s ON s.usage_date = c.usage_date
),
x AS (
  SELECT j.*,
         CASE WHEN snowflake_anomaly THEN GREATEST(COALESCE(sf_actual_credits, our_credits) - COALESCE(sf_upper_bound, our_baseline_credits, 0), 0)
              WHEN our_spike THEN GREATEST(our_credits - our_baseline_credits, 0) END AS excess_credits
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date, our_credits, our_baseline_credits,
       our_spike, snowflake_row, snowflake_anomaly, sf_actual_credits, sf_upper_bound, sf_lower_bound,
       sf_forecast_credits,
       CASE WHEN snowflake_anomaly AND our_spike THEN 'both' WHEN snowflake_anomaly THEN 'snowflake only'
            WHEN our_spike THEN 'audit only' ELSE 'neither' END AS agreement,
       excess_credits, excess_credits * __CREDIT_PRICE__ AS est_change_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(snowflake_anomaly, 'Snowflake flags it', NULL),
         IFF(our_spike, 'audit spike: ' || ROUND(our_credits / NULLIF(our_baseline_credits, 0), 1) || 'x its baseline', NULL),
         IFF(NOT snowflake_row, 'no Snowflake row for the day yet', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN snowflake_anomaly AND our_spike AND excess_credits >= :crit_credits THEN 'CRITICAL'
         WHEN snowflake_anomaly OR our_spike THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM x
ORDER BY usage_date DESC
