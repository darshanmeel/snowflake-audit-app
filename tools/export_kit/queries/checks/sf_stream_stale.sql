-- query_id: sf_stream_stale
-- title: Streams that are stale, broken or not being consumed
-- domain: jobs_pipelines   tier: standard
-- entity: streams = stream_fqn
-- windowed: no
-- pre: SHOW STREAMS IN ACCOUNT
-- reads: SHOW STREAMS IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those)
-- params: :warn_days_to_stale (default 5) days to stale: at or above this the row reads WARN;
--   :crit_days_to_stale (default 2) days to stale: at or above this the row reads CRITICAL; :idle_days
--   (default 14) idle days: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one stream. stale_after is when the stream's offset falls out of the source's
--   retention (plus MAX_DATA_EXTENSION_TIME_IN_DAYS) and the stream becomes unreadable; every consume
--   (a DML that reads the stream) moves it forward. days_to_stale counts from the export cut-off (the earlier of now and the as-of date). last_read_at is the
--   last query that read the stream within idle_days (ACCESS_HISTORY); source_retention_days is the
--   source table's DATA_RETENTION_TIME_IN_DAYS.
-- healthy: status = OK when the stream is valid, not stale, is read regularly and stale_after is more
--   than warn_days_to_stale away.
-- investigate_if: WARN when stale_after is within warn_days_to_stale days, or nothing read the stream
--   in idle_days; CRITICAL when the stream is already stale, invalid (source dropped or changed), or
--   stale_after is within crit_days_to_stale days.
-- actions: 1) find the consumer (task, dbt model, job) and make it run, or drop a stream nobody uses
--   (free); 2) a stale stream cannot be repaired: recreate it and backfill the gap from the source
--   (engineering); 3) raise MAX_DATA_EXTENSION_TIME_IN_DAYS on sources whose consumers run rarely
--   (config, keeps more Time Travel bytes).
-- next: none
-- caveats: SHOW STREAMS lists what the export role can see and returns at most 10,000 rows. Stream
--   reads in ACCESS_HISTORY need Enterprise Edition; with no stream reads at all, "not consumed" is not
--   judged (not_assessed_reason). A SELECT on a stream reads it without moving the offset, so
--   last_read_at can be recent while stale_after still approaches.
WITH s AS (
  SELECT "database_name" AS database_name, "schema_name" AS schema_name, "name" AS stream_name,
         "database_name" || '.' || "schema_name" || '.' || "name" AS stream_fqn,
         "owner" AS stream_owner, "table_name" AS source_fqn, "source_type" AS source_type,
         "type" AS stream_type, "mode" AS stream_mode,
         LOWER(TO_VARCHAR("stale")) = 'true' AS is_stale,
         CAST("stale_after" AS TIMESTAMP_LTZ) AS stale_after,
         NULLIF(NULLIF(TRIM("invalid_reason"), ''), 'N/A') AS invalid_reason,
         CAST("created_on" AS TIMESTAMP_LTZ) AS created_on
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
src AS (
  SELECT UPPER(table_catalog || '.' || table_schema || '.' || table_name) AS source_key,
         MAX(retention_time) AS retention_time, MAX(is_transient) AS is_transient
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  GROUP BY 1
),
-- Stream reads show up as direct objects with domain Stream.
reads AS (
  SELECT UPPER(f.value:objectName::STRING) AS stream_key, MAX(ah.query_start_time) AS last_read_at,
         COUNT(DISTINCT ah.query_id) AS read_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.direct_objects_accessed) f
  WHERE ah.query_start_time >= DATEADD(day, -:idle_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
    AND f.value:objectDomain::STRING = 'Stream'
  GROUP BY 1
),
seen AS (
  SELECT COUNT(*) AS streams_read FROM reads
),
j AS (
  SELECT s.*, src.retention_time AS source_retention_days, src.is_transient AS source_is_transient,
         r.last_read_at, COALESCE(r.read_queries, 0) AS read_queries,
         DATEDIFF(minute, LEAST(CURRENT_TIMESTAMP(), CAST(__AS_OF_DATE__ AS TIMESTAMP)), s.stale_after) / 1440 AS days_to_stale,
         (r.stream_key IS NULL AND s.created_on < DATEADD(day, -:idle_days, __AS_OF_DATE__)) AS not_consumed,
         seen.streams_read
  FROM s
  LEFT JOIN src ON src.source_key = UPPER(REPLACE(s.source_fqn, '"', ''))
  LEFT JOIN reads r ON r.stream_key = UPPER(s.stream_fqn)
  CROSS JOIN seen
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       stream_fqn, stream_name, database_name, schema_name, stream_owner, source_fqn, source_type,
       stream_type, stream_mode, is_stale, stale_after, ROUND(days_to_stale, 1) AS days_to_stale,
       invalid_reason, source_retention_days, source_is_transient, created_on, last_read_at, read_queries,
       :idle_days AS idle_days,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(invalid_reason IS NOT NULL, 'invalid: ' || invalid_reason, NULL),
         IFF(is_stale, 'stale: changes are lost, recreate the stream', NULL),
         IFF(NOT is_stale AND days_to_stale <= :warn_days_to_stale,
             'goes stale in ' || ROUND(days_to_stale, 1) || ' days', NULL),
         IFF(streams_read > 0 AND not_consumed, 'not read in ' || :idle_days || ' days', NULL)), '; ') AS reasons,
       CASE WHEN streams_read = 0 THEN 'no_stream_reads_in_access_history' END AS not_assessed_reason,
       CASE
         WHEN invalid_reason IS NOT NULL OR is_stale OR days_to_stale <= :crit_days_to_stale THEN 'CRITICAL'
         WHEN days_to_stale <= :warn_days_to_stale THEN 'WARN'
         WHEN streams_read > 0 AND not_consumed THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, days_to_stale NULLS LAST
