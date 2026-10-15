-- query_id: sf_acct_observability_cost
-- title: Data quality monitoring and event table spend
-- domain: cost   tier: standard
-- entity: observability features = feature, object_id
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATA_QUALITY_MONITORING_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 25) usd: at or above this the row reads WARN; :crit_usd (default 250) usd:
--   at or above this the row reads CRITICAL; :warn_increase_pct (default 50) increase pct: at or above
--   this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table whose data metric functions (DMFs) Snowflake ran serverlessly, plus
--   one EVENT_TABLE row for log / trace / metric ingestion into event tables. credits_used is the
--   window, previous_credits the window before. runs_hours counts the hours with DMF activity, a proxy
--   for how often the schedule fires. Neither spend shows up under any warehouse.
-- healthy: status = OK when the spend stays under warn_usd, or is flat.
-- investigate_if: WARN when spend >= warn_usd and it is new or grew >= warn_increase_pct; CRITICAL when
--   spend >= crit_usd.
-- actions: 1) drop DMFs from tables nobody reads and remove duplicate metrics (free); 2) change
--   DATA_METRIC_SCHEDULE from minutes to TRIGGER_ON_CHANGES or a daily cron (config); 3) lower
--   LOG_LEVEL / TRACE_LEVEL / METRIC_LEVEL on chatty UDFs, procedures and apps (config).
-- next: none
-- caveats: both views lag up to 3 hours; event ingestion is account-wide in the view, so it is not
--   split by event table or emitter. Serverless credits carry Snowflake's feature multiplier already.
WITH dq AS (
  SELECT 'DATA_METRIC_FUNCTIONS' AS feature, TO_VARCHAR(table_id) AS object_id,
         MAX(database_name || '.' || schema_name || '.' || table_name) AS object_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS previous_credits,
         COUNT(DISTINCT IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__),
                            DATE_TRUNC(hour, start_time), NULL)) AS active_hours,
         CAST(NULL AS NUMBER) AS bytes_ingested
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_QUALITY_MONITORING_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
),
ev AS (
  SELECT 'EVENT_TABLE' AS feature, 'EVENT_TABLE' AS object_id, 'event table ingestion (all event tables)' AS object_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS previous_credits,
         COUNT(DISTINCT IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__),
                            DATE_TRUNC(hour, start_time), NULL)) AS active_hours,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), bytes, 0)) AS bytes_ingested
  -- EVENT_USAGE_HISTORY is deprecated; event ingestion is a METERING_HISTORY service type.
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE service_type = 'TELEMETRY_DATA_INGEST' AND start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  HAVING COUNT(*) > 0
),
u AS (
  SELECT * FROM dq UNION ALL SELECT * FROM ev
),
scored AS (
  SELECT u.*, credits * __CREDIT_PRICE__ AS usd,
         100 * (credits - previous_credits) / NULLIF(previous_credits, 0) AS change_pct
  FROM u
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       feature, object_id, object_name, credits AS credits_used, previous_credits, change_pct,
       active_hours, bytes_ingested / POWER(1024, 3) AS gb_ingested,
       usd AS est_observability_usd_list, previous_credits * __CREDIT_PRICE__ AS est_previous_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(usd >= :warn_usd, ROUND(usd) || ' USD in the window', NULL),
         IFF(previous_credits = 0 AND credits > 0, 'new spend', NULL),
         IFF(change_pct >= :warn_increase_pct, 'up ' || ROUND(change_pct) || '%', NULL)), '; ') AS reasons,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd AND (previous_credits = 0 OR change_pct >= :warn_increase_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
WHERE credits > 0 OR previous_credits > 0
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, credits DESC
