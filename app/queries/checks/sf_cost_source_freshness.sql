-- query_id: sf_cost_source_freshness
-- title: How fresh the usage views are: newest row and days missing before the cut-off
-- domain: cost   tier: standard
-- entity: usage views = source_view
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE,
--   SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :lookback_days (default 14) days: a view with no row in this many days reads as empty;
--   :crit_days_behind (default 3) days: a view this many complete days behind the cut-off reads CRITICAL
-- empty_if: ingestion_lag
-- not_assessed_reasons: no_rows_in_lookback: the view has no row in the lookback, so its freshness cannot be judged
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one usage view the audit reads. newest_time is its latest row (the end of the day for
--   a daily view). days_behind is how many complete days before the audit's last complete day the newest row
--   is; 0 means the last complete day is there. lag_hours is the age of the newest row at the cut-off.
--   feed_kind: billing and always_on views should have a row every day; activity views (tasks, loading)
--   are quiet when nothing ran, so they are never flagged.
-- healthy: status = OK when the newest row reaches the last complete day.
-- investigate_if: WARN when a billing or always_on view is 1 or more complete days behind; CRITICAL at
--   :crit_days_behind or more.
-- actions: 1) wait for the documented latency and re-run the export before trusting a "nothing found" (free);
--   2) if a view stays behind, ask Snowflake Support: the audit's spend for those days is too low (free);
--   3) re-run the export with the role that can read the view if it comes back empty (config)
-- next: none
-- caveats: The check reads only the newest row of the last :lookback_days days per view. Views that need
--   Enterprise Edition (ACCESS_HISTORY) and the organization views (up to 72 h behind, organization account
--   only) are not read here. The cut-off is the audit's as-of date, not the calendar day.
WITH feeds AS (
  SELECT 'WAREHOUSE_METERING_HISTORY' AS source_view, 'billing' AS feed_kind, 3 AS expected_latency_hours,
         DATE(MAX(end_time)) AS newest_day, CAST(MAX(end_time) AS TIMESTAMP_NTZ) AS newest_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE end_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'METERING_HISTORY', 'billing', 3, DATE(MAX(end_time)), CAST(MAX(end_time) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE end_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'METERING_DAILY_HISTORY', 'billing', 3, MAX(usage_date),
         CAST(DATEADD(day, 1, MAX(usage_date)) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'STORAGE_USAGE', 'billing', 2, MAX(usage_date), CAST(DATEADD(day, 1, MAX(usage_date)) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
  WHERE usage_date >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'DATABASE_STORAGE_USAGE_HISTORY', 'billing', 3, MAX(usage_date),
         CAST(DATEADD(day, 1, MAX(usage_date)) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'QUERY_HISTORY', 'always_on', 1, DATE(MAX(end_time)), CAST(MAX(end_time) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE end_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'QUERY_ATTRIBUTION_HISTORY', 'always_on', 8, DATE(MAX(end_time)), CAST(MAX(end_time) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE end_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'LOGIN_HISTORY', 'always_on', 2, DATE(MAX(event_timestamp)), CAST(MAX(event_timestamp) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'SESSIONS', 'always_on', 3, DATE(MAX(created_on)), CAST(MAX(created_on) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  WHERE created_on >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'TASK_HISTORY', 'activity', 1, DATE(MAX(scheduled_time)), CAST(MAX(scheduled_time) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
  UNION ALL
  SELECT 'COPY_HISTORY', 'activity', 2, DATE(MAX(last_load_time)), CAST(MAX(last_load_time) AS TIMESTAMP_NTZ)
  FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
  WHERE last_load_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
),
s AS (
  SELECT f.*,
         GREATEST(DATEDIFF(day, newest_day, DATEADD(day, -1, __AS_OF_DATE__)), 0) AS days_behind,
         GREATEST(DATEDIFF(hour, newest_time, CAST(__AS_OF_DATE__ AS TIMESTAMP_NTZ)), 0) AS lag_hours
  FROM feeds f
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, 'ACCOUNT_USAGE' AS source_schema, source_view, feed_kind,
       expected_latency_hours, newest_time, days_behind, lag_hours,
       CASE WHEN newest_time IS NULL THEN 'no row in the last ' || :lookback_days || ' days'
            WHEN days_behind > 0 THEN 'newest row is ' || days_behind || ' complete days behind the cut-off'
       END AS reasons,
       CASE WHEN newest_time IS NULL AND feed_kind <> 'activity' THEN 'no_rows_in_lookback' END AS not_assessed_reason,
       CASE
         WHEN feed_kind = 'activity' THEN 'OK'
         WHEN newest_time IS NULL THEN 'NOT_ASSESSED'
         WHEN days_behind >= :crit_days_behind THEN 'CRITICAL'
         WHEN days_behind >= 1 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END, source_view
