-- query_id: sf_load_streaming_cost
-- title: What Snowpipe Streaming costs
-- domain: jobs_pipelines   tier: standard
-- money: est_streaming_usd_list
-- entity: streaming objects = cost_kind, object_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SNOWPIPE_STREAMING_CLIENT_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 50) usd: at or above this the row reads WARN; :crit_usd (default 500) usd:
--   at or above this the row reads CRITICAL; :warn_growth_pct (default 50) growth pct: at or above this
--   the row reads WARN; :min_growth_usd (default 10) growth usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one cost line of Snowpipe Streaming. cost_kind = metered: the credits METERING_HISTORY bills for
--   Snowpipe Streaming (service SNOWPIPE_STREAMING, migration included), with blob activity from
--   SNOWPIPE_STREAMING_CLIENT_HISTORY when the names match; cost_kind = migration: the part of those
--   credits spent rewriting streamed data into table files, per target table. Migration rows carry no
--   $ of their own (est_migration_within_usd_list) so nothing is counted twice. active_hours is the number of hours a
--   client uploaded anything (clients bill while they are active).
-- healthy: status = OK when the line costs under warn_usd and did not grow by warn_growth_pct.
-- investigate_if: WARN when est_streaming_usd_list >= warn_usd, or it grew >= warn_growth_pct and by >=
--   min_growth_usd; CRITICAL when est_streaming_usd_list >= crit_usd.
-- actions: 1) close idle clients and reuse one client per application instead of many (free); 2) for
--   migration cost, avoid clustering keys and frequent small updates on streaming targets (config); 3)
--   compare with file-based Snowpipe for low-volume feeds (config).
-- next: none
-- caveats: METERING_HISTORY names the metered entity; whether NAME equals the client name depends on
--   the account, so blob columns can be empty. Both Snowpipe Streaming architectures bill under
--   SNOWPIPE_STREAMING in METERING_HISTORY, which already includes the file migration credits, so those
--   are counted once (metered rows) and the migration rows only break part of them out. File-based
--   Snowpipe (PIPE_USAGE_HISTORY, sf_pipe_cost_and_files) is a separate bill. Lags up to 3 hours.
WITH m AS (
  SELECT 'metered' AS cost_kind, TO_VARCHAR(entity_id) AS object_id, MAX(name) AS object_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS prev_credits,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), bytes, 0)) AS bytes_ingested,
         -- ROWS is a reserved word, so the column is quoted.
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), "ROWS", 0)) AS rows_ingested
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND service_type = 'SNOWPIPE_STREAMING'
  GROUP BY 2
),
c AS (
  SELECT client_name, COUNT(*) AS blobs, SUM(blob_size_bytes) AS blob_bytes,
         COUNT(DISTINCT DATE_TRUNC('hour', event_timestamp)) AS active_hours,
         MAX(event_timestamp) AS last_event_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPIPE_STREAMING_CLIENT_HISTORY
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
  GROUP BY 1
),
fm AS (
  SELECT 'migration' AS cost_kind, TO_VARCHAR(table_id) AS object_id,
         MAX(database_name || '.' || schema_name || '.' || table_name) AS object_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS prev_credits,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), num_bytes_migrated, 0)) AS bytes_ingested,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), num_rows_migrated, 0)) AS rows_ingested
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 2
),
lines AS (
  SELECT m.*, c.blobs, c.blob_bytes, c.active_hours, c.last_event_time
  FROM m LEFT JOIN c ON c.client_name = m.object_name
  UNION ALL
  SELECT fm.*, NULL, NULL, NULL, NULL FROM fm
),
scored AS (
  SELECT lines.*, credits * __CREDIT_PRICE__ AS usd, prev_credits * __CREDIT_PRICE__ AS prev_usd,
         bytes_ingested / POWER(1024, 3) AS gb
  FROM lines
  WHERE credits > 0 OR prev_credits > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       cost_kind, object_name, object_id, credits, prev_credits,
       100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
       gb AS gb_ingested, rows_ingested, blobs, blob_bytes / POWER(1024, 3) AS blob_gb, active_hours,
       last_event_time,
       IFF(cost_kind = 'migration', NULL, usd) AS est_streaming_usd_list,
       IFF(cost_kind = 'migration', usd, NULL) AS est_migration_within_usd_list,
       IFF(cost_kind = 'migration', NULL, prev_usd) AS est_prev_usd_list,
       IFF(cost_kind = 'migration', NULL, usd / NULLIF(gb, 0)) AS est_usd_per_gb,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       cost_kind || ' ' || object_name || ': ' || ROUND(credits, 2) || ' credits (previous window '
         || ROUND(prev_credits, 2) || ')' AS cost_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd
           OR (usd - prev_usd >= :min_growth_usd
               AND 100 * (credits - prev_credits) / NULLIF(prev_credits, 0) >= :warn_growth_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY est_streaming_usd_list DESC NULLS LAST, credits DESC
