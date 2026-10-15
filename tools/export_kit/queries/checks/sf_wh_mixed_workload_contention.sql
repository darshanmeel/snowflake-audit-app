-- query_id: sf_wh_mixed_workload_contention
-- title: Pipeline writes that make interactive queries queue on a shared warehouse
-- domain: compute   tier: standard
-- windowed: yes
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :pipeline_hour_pct (default 50) percent of an hour's run time in pipeline writes at or above
--   which the hour counts as a pipeline hour; :min_queued (default 30) interactive queries that queued
--   before a warehouse can flag; :min_quiet_reads (default 100) interactive queries outside pipeline hours
--   needed to compare the two; :warn_lift (default 2) times more often interactive queries queue in
--   pipeline hours than in other hours at or above which the row reads WARN; :crit_lift (default 4) the
--   same that reads CRITICAL, when at least 10% of interactive queries in pipeline hours queue
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. Pipeline work is INSERT, MERGE, UPDATE, DELETE, COPY, CREATE TABLE
--   AS SELECT, multi-table INSERT and UNLOAD; interactive work is SELECT. Each UTC hour is a pipeline hour
--   when pipeline statements started in it take at least pipeline_hour_pct of its run time and at least
--   a minute. queued_pct_pipeline_hours and queued_pct_other_hours are the shares of interactive queries
--   that waited for a busy warehouse (queued_overload_time) in pipeline hours and in the other hours;
--   lift is the first over the second. A high lift means the pipeline crowds out the people and
--   dashboards on the same warehouse: move or reschedule the pipeline rather than upsize the warehouse
--   for everyone. queued_in_pipeline_hours_pct is the share of all interactive queue time that falls in
--   pipeline hours. top_pipeline_user_name and peak_pipeline_hour_utc name the main writer in pipeline hours
--   and the hour of day its queue is worst. verdict: pipeline_crowds_out, queue_from_reads (queueing
--   with no lift), no_quiet_hours (pipelines run in nearly every hour with reads, so there is nothing to
--   compare), no_queue, single_workload. Context, no $.
-- healthy: status = OK when interactive queries rarely queue, or queue as often outside pipeline hours
-- investigate_if: WARN when at least min_queued interactive queries queued, min_quiet_reads ran outside
--   pipeline hours, and lift >= warn_lift; CRITICAL when lift >= crit_lift and at least 10% of
--   interactive queries in pipeline hours queued
-- actions: 1) run the pipeline on its own warehouse, sized for it, with a short auto-suspend (config);
--   2) move the pipeline out of the hours people query (free); 3) if both must share, allow a second
--   cluster (MAX_CLUSTER_COUNT = 2, Enterprise edition) instead of a bigger size (config)
-- next: sf_wh_multicluster_scaling, sf_wh_load_utilization
-- caveats: heavy: reads QUERY_HISTORY for the window (period_days only), aggregated per warehouse and
--   hour in Snowflake. A statement counts in the hour it started, so long writes spill into the next
--   hour uncounted. A SELECT run by a pipeline counts as interactive. Queueing also comes from bursts of
--   interactive queries alone; the lift tells the two apart.
WITH -- Current warehouse settings from the SHOW WAREHOUSES run just before (a check's `-- pre:` line),
-- with the numeric id taken from metering history by name. credits_per_hour is the Service
-- Consumption Table rate for the size, generation and resource constraint (rate_multiplier is its
-- ratio to a Gen1 standard warehouse of the same size; multi-cluster warehouses pay it per running
-- cluster; an estimate input, never billed spend). SHOW returns the counts and
-- auto_suspend as NUMBER, so they are cast, not TRY_TO_NUMBER'd (that takes text only).
-- An ADAPTIVE warehouse has no size, cluster counts or auto_suspend in SHOW, so those stay NULL.
warehouse_show AS (
  SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
-- Newer SHOW columns are read by key, since not every account returns them (is_interactive is AWS only).
warehouse_show_opt AS (
  SELECT r."name", r."type", r."size", r."state", r."min_cluster_count", r."max_cluster_count",
         r."auto_suspend", r."auto_resume", r."scaling_policy", r."resource_monitor", r."owner",
         r."enable_query_acceleration", r."updated_on", r."created_on",
         r.o:"resource_constraint"::VARCHAR AS "resource_constraint",
         r.o:"generation"::VARCHAR AS "generation",
         r.o:"is_interactive"::VARCHAR AS "is_interactive"
  FROM (SELECT w.*, OBJECT_CONSTRUCT(*) AS o FROM warehouse_show w) r
),
warehouse_config AS (
  SELECT COALESCE(TO_VARCHAR(ids.warehouse_id), s."name") AS warehouse_id,
         s."name" AS warehouse_name, s."type" AS warehouse_type, s."size" AS warehouse_size,
         s."state" AS warehouse_state,
         CAST(s."min_cluster_count" AS NUMBER) AS min_clusters,
         CAST(s."max_cluster_count" AS NUMBER) AS max_clusters,
         CAST(s."auto_suspend" AS NUMBER) / 60 AS auto_stop_minutes,
         s."auto_resume" AS auto_resume, s."scaling_policy" AS scaling_policy,
         s."resource_monitor" AS resource_monitor, s."owner" AS owner,
         s."enable_query_acceleration" AS query_acceleration, s."updated_on" AS updated_on,
         s."created_on" AS created_on,
         s."resource_constraint" AS resource_constraint,
         CASE WHEN UPPER(s."type") = 'ADAPTIVE' THEN 'ADAPTIVE'
              WHEN UPPER(s."type") = 'SNOWPARK-OPTIMIZED' THEN 'SNOWPARK_OPTIMIZED'
              WHEN UPPER(COALESCE(s."resource_constraint", '')) = 'STANDARD_GEN_2'
                   OR s."generation" = '2' THEN 'GEN2'
              ELSE 'GEN1' END AS warehouse_generation,
         CASE UPPER(REPLACE(s."size", '-', ''))
           WHEN 'XSMALL' THEN 1 WHEN 'SMALL' THEN 2 WHEN 'MEDIUM' THEN 4 WHEN 'LARGE' THEN 8
           WHEN 'XLARGE' THEN 16 WHEN '2XLARGE' THEN 32 WHEN 'XXLARGE' THEN 32
           WHEN '3XLARGE' THEN 64 WHEN 'XXXLARGE' THEN 64 WHEN '4XLARGE' THEN 128
           WHEN '5XLARGE' THEN 256 WHEN '6XLARGE' THEN 512
         END * s.rate_multiplier AS credits_per_hour,
         s.rate_multiplier
  FROM (
    -- Multipliers from Tables 1(b) to 1(d) of the Service Consumption Table (Gen2 is 1.25 on Azure,
    -- 1.35 elsewhere; Snowpark-optimized by resource constraint; interactive 0.6).
    SELECT r.*, CASE
      -- adaptive warehouses have no fixed hourly rate: unknown, never a size-based guess
      WHEN UPPER(r."type") = 'ADAPTIVE' THEN CAST(NULL AS DOUBLE)
      WHEN UPPER(r."type") = 'SNOWPARK-OPTIMIZED' THEN
        -- MEMORY_16X is the documented default for Snowpark-optimized (CREATE WAREHOUSE)
        CASE UPPER(COALESCE(r."resource_constraint", 'MEMORY_16X'))
          WHEN 'MEMORY_1X_X86' THEN 1.1 WHEN 'MEMORY_16X' THEN 1.5 WHEN 'MEMORY_16X_X86' THEN 1.5625
          WHEN 'MEMORY_64X' THEN 1.875 WHEN 'MEMORY_64X_X86' THEN 2.0 ELSE 1.0 END
      WHEN UPPER(r."type") = 'INTERACTIVE' OR LOWER(r."is_interactive") IN ('true', 'y') THEN 0.6
      WHEN UPPER(COALESCE(r."resource_constraint", '')) = 'STANDARD_GEN_2' OR r."generation" = '2'
        THEN IFF(__CLOUD__ = 'AZURE', 1.25, 1.35)
      ELSE 1.0 END AS rate_multiplier
    FROM warehouse_show_opt r
  ) s
  LEFT JOIN (
    SELECT warehouse_name, MAX(warehouse_id) AS warehouse_id
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD(day, -400, __AS_OF_DATE__)
    GROUP BY warehouse_name
  ) ids ON ids.warehouse_name = s."name"
),
q AS (
  SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hr, user_name,
         CASE WHEN query_type IN ('INSERT', 'MERGE', 'UPDATE', 'DELETE', 'COPY', 'CREATE_TABLE_AS_SELECT', 'UNLOAD',
                                  'MULTI_TABLE_INSERT') THEN 'pipeline'
              WHEN query_type = 'SELECT' THEN 'read' END AS kind,
         COALESCE(execution_time, 0) AS exec_ms, COALESCE(queued_overload_time, 0) AS queued_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
),
h AS (
  -- one row per warehouse and hour
  SELECT warehouse_name, hr,
         SUM(IFF(kind = 'pipeline', exec_ms, 0)) AS pipe_ms,
         SUM(IFF(kind = 'read', exec_ms, 0)) AS read_ms,
         COUNT_IF(kind = 'read') AS reads,
         COUNT_IF(kind = 'read' AND queued_ms > 0) AS reads_queued,
         SUM(IFF(kind = 'read', queued_ms, 0)) AS read_queued_ms
  FROM q
  WHERE kind IS NOT NULL
  GROUP BY 1, 2
),
hp AS (
  SELECT h.*, pipe_ms >= 60000 AND 100 * pipe_ms / NULLIF(pipe_ms + read_ms, 0) >= :pipeline_hour_pct AS is_pipe_hour
  FROM h
),
w AS (
  SELECT warehouse_name, SUM(reads) AS reads, SUM(reads_queued) AS reads_queued,
         SUM(IFF(is_pipe_hour, reads, 0)) AS reads_pipe, SUM(IFF(is_pipe_hour, reads_queued, 0)) AS queued_pipe,
         SUM(IFF(is_pipe_hour, 0, reads)) AS reads_other, SUM(IFF(is_pipe_hour, 0, reads_queued)) AS queued_other,
         SUM(read_queued_ms) AS read_queued_ms,
         SUM(IFF(is_pipe_hour, read_queued_ms, 0)) AS read_queued_ms_pipe,
         COUNT_IF(is_pipe_hour) AS pipeline_hours, SUM(pipe_ms) AS pipe_ms
  FROM hp
  GROUP BY 1
),
peak AS (
  -- the UTC hour of day whose pipeline hours hold the most interactive queue time
  SELECT warehouse_name, HOUR(hr) AS peak_pipeline_hour_utc
  FROM hp
  WHERE is_pipe_hour AND read_queued_ms > 0
  GROUP BY 1, 2
  QUALIFY ROW_NUMBER() OVER (PARTITION BY warehouse_name ORDER BY SUM(read_queued_ms) DESC, HOUR(hr)) = 1
),
pu AS (
  SELECT q.warehouse_name, q.user_name AS top_pipeline_user_name
  FROM q JOIN hp ON hp.warehouse_name = q.warehouse_name AND hp.hr = q.hr AND hp.is_pipe_hour
  WHERE q.kind = 'pipeline'
  GROUP BY 1, 2
  QUALIFY ROW_NUMBER() OVER (PARTITION BY q.warehouse_name ORDER BY SUM(q.exec_ms) DESC, q.user_name) = 1
),
r AS (
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_size, CAST(c.max_clusters AS INTEGER) AS max_clusters,
         COALESCE(w.reads, 0) AS reads, COALESCE(w.reads_queued, 0) AS reads_queued,
         COALESCE(w.reads_pipe, 0) AS reads_pipe, COALESCE(w.reads_other, 0) AS reads_other,
         100 * w.reads_queued / NULLIF(w.reads, 0) AS read_queued_pct,
         100 * w.queued_pipe / NULLIF(w.reads_pipe, 0) AS queued_pct_pipe,
         100 * w.queued_other / NULLIF(w.reads_other, 0) AS queued_pct_other,
         w.read_queued_ms / 3600000 AS read_queued_hours,
         100 * w.read_queued_ms_pipe / NULLIF(w.read_queued_ms, 0) AS queued_in_pipeline_hours_pct,
         COALESCE(w.pipeline_hours, 0) AS pipeline_hours, COALESCE(w.pipe_ms, 0) AS pipe_ms,
         pu.top_pipeline_user_name, peak.peak_pipeline_hour_utc
  FROM warehouse_config c
  LEFT JOIN w ON w.warehouse_name = c.warehouse_name
  LEFT JOIN pu ON pu.warehouse_name = c.warehouse_name
  LEFT JOIN peak ON peak.warehouse_name = c.warehouse_name
),
v AS (
  -- no queueing at all outside pipeline hours reads as a lift of 10: queueing only while pipelines run
  SELECT r.*,
         CASE WHEN queued_pct_pipe IS NULL OR queued_pct_pipe = 0 THEN NULL
              WHEN COALESCE(queued_pct_other, 0) = 0 THEN 10
              ELSE LEAST(queued_pct_pipe / queued_pct_other, 10) END AS lift
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, warehouse_size,
       max_clusters, reads, reads_queued, ROUND(read_queued_pct, 1) AS read_queued_pct,
       reads_pipe, ROUND(queued_pct_pipe, 1) AS queued_pct_pipeline_hours, reads_other,
       ROUND(queued_pct_other, 1) AS queued_pct_other_hours, ROUND(lift, 1) AS lift,
       ROUND(read_queued_hours, 2) AS read_queued_hours, ROUND(queued_in_pipeline_hours_pct, 1) AS queued_in_pipeline_hours_pct,
       pipeline_hours, top_pipeline_user_name, peak_pipeline_hour_utc,
       CASE WHEN pipe_ms = 0 OR reads = 0 THEN 'single_workload'
            WHEN reads_queued = 0 THEN 'no_queue'
            WHEN reads_pipe > 0 AND reads_other < :min_quiet_reads THEN 'no_quiet_hours'
            WHEN lift >= :warn_lift THEN 'pipeline_crowds_out'
            ELSE 'queue_from_reads' END AS verdict,
       CASE
         WHEN reads_queued >= :min_queued AND reads_other >= :min_quiet_reads AND lift >= :crit_lift
              AND queued_pct_pipe >= 10 THEN 'CRITICAL'
         WHEN reads_queued >= :min_queued AND reads_other >= :min_quiet_reads AND lift >= :warn_lift THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM v
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, read_queued_hours DESC NULLS LAST, warehouse_name
