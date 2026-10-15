-- query_id: sf_load_streaming_channel_errors
-- title: Snowpipe Streaming channels that drop rows, lag or went quiet
-- domain: jobs_pipelines   tier: standard
-- entity: streaming channels = channel_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SNOWPIPE_STREAMING_CHANNEL_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_error_pct (default 0.1) error pct: at or above this share of parsed rows failing the
--   row reads WARN; :crit_error_pct (default 1) error pct: at or above this the row reads CRITICAL;
--   :warn_latency_seconds (default 60) seconds: an average Snowflake processing latency at or above this
--   reads WARN; :quiet_hours (default 24) hours: a channel with no snapshot for this long before the
--   export date reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Row grain of the view is not documented in full.
-- read_this: one row = one Snowpipe Streaming channel (high-performance architecture) with a snapshot in
--   the window. Row counters in the view are running totals, so error_rows_window is the latest total
--   minus the first total seen in the window. avg_latency_seconds is how long Snowflake took to process
--   rowsets; hours_since_last_snapshot shows a channel that stopped reporting.
-- healthy: status = OK when under warn_error_pct of parsed rows failed, latency stays under
--   warn_latency_seconds and the channel reported within quiet_hours.
-- investigate_if: WARN when error_pct >= warn_error_pct, latency >= warn_latency_seconds or the channel
--   is quiet; CRITICAL when error_pct >= crit_error_pct.
-- actions: 1) look at the client's error log for the rows the channel rejected, and fix the data or the
--   mapping (free); 2) check the client still runs and reopens its channel after restarts (free); 3) if
--   latency is high, batch fewer, larger rowsets or split the load over more channels (config).
-- next: sf_load_streaming_cost
-- empty_if: view_missing, no_activity, ingestion_lag
-- caveats: only the high-performance Snowpipe Streaming architecture writes this view, so classic
--   channels are not listed and an empty result is not a clean bill. The view lags up to 12 hours. The
--   error message and offset token are never stored. A channel quiet for the whole window is not listed.
WITH c AS (
  SELECT channel_id, channel_name, pipe_id, pipe_name,
         table_id, table_database_name, table_schema_name, table_name,
         created_on, rows_inserted, rows_parsed, row_error_count,
         snowflake_processing_latency_ms, last_error_offset_upper_bound
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPIPE_STREAMING_CHANNEL_HISTORY
  WHERE created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND created_on < __AS_OF_DATE__
),
ch AS (
  SELECT channel_id, MAX(channel_name) AS channel_name, MAX(pipe_id) AS pipe_id, MAX(pipe_name) AS pipe_name,
         MAX(table_id) AS table_id,
         MAX(table_database_name || '.' || table_schema_name || '.' || table_name) AS table_full_name,
         COUNT(*) AS snapshots, MAX(created_on) AS last_snapshot,
         MAX_BY(rows_inserted, created_on) AS rows_inserted_last,
         MIN_BY(rows_inserted, created_on) AS rows_inserted_first,
         MAX_BY(rows_parsed, created_on) AS rows_parsed_last,
         MIN_BY(rows_parsed, created_on) AS rows_parsed_first,
         MAX_BY(row_error_count, created_on) AS errors_last,
         MIN_BY(row_error_count, created_on) AS errors_first,
         AVG(snowflake_processing_latency_ms) AS avg_latency_ms,
         MAX(snowflake_processing_latency_ms) AS max_latency_ms,
         MAX(IFF(last_error_offset_upper_bound IS NOT NULL, 1, 0)) AS had_error_offset
  FROM c
  GROUP BY channel_id
),
s AS (
  SELECT ch.*,
         -- Running totals: a lower latest value means the channel was recreated, so use the latest as is.
         IFF(errors_last >= errors_first, errors_last - errors_first, errors_last) AS error_rows_window,
         IFF(rows_parsed_last >= rows_parsed_first, rows_parsed_last - rows_parsed_first, rows_parsed_last) AS parsed_rows_window,
         IFF(rows_inserted_last >= rows_inserted_first, rows_inserted_last - rows_inserted_first, rows_inserted_last) AS inserted_rows_window,
         DATEDIFF('hour', last_snapshot, __AS_OF_DATE__) AS hours_since_last_snapshot
  FROM ch
),
e AS (
  SELECT s.*, 100 * error_rows_window / NULLIF(parsed_rows_window, 0) AS error_pct FROM s
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       COALESCE(channel_name, 'unknown') || ' (' || TO_VARCHAR(channel_id) || ')' AS channel_full_name,
       TO_VARCHAR(channel_id) AS channel_id,
       COALESCE(pipe_name, 'unknown') || ' (' || COALESCE(TO_VARCHAR(pipe_id), '?') || ')' AS pipe_full_name,
       table_full_name, TO_VARCHAR(table_id) AS table_id, snapshots, last_snapshot,
       hours_since_last_snapshot, inserted_rows_window, parsed_rows_window, error_rows_window,
       errors_last AS error_rows_total, ROUND(error_pct, 3) AS error_pct,
       ROUND(avg_latency_ms / 1000, 2) AS avg_latency_seconds,
       ROUND(max_latency_ms / 1000, 2) AS max_latency_seconds,
       had_error_offset = 1 AS had_error_offset,
       error_rows_window || ' of ' || parsed_rows_window || ' rows failed; latency '
         || COALESCE(ROUND(avg_latency_ms / 1000, 1) || ' s', 'unknown') AS risk_reason,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN error_pct >= :crit_error_pct THEN 'CRITICAL'
         WHEN error_pct >= :warn_error_pct OR avg_latency_ms / 1000 >= :warn_latency_seconds
           OR hours_since_last_snapshot >= :quiet_hours THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM e
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, error_rows_window DESC NULLS LAST
