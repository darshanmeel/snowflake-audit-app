-- query_id: sf_wh_auto_suspend_tuning
-- title: Auto-suspend options, idle gaps, resume wait and cache per warehouse
-- domain: compute   tier: standard
-- windowed: yes
-- money: est_saving_usd_list
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_saving_credits (default 20) saving credits at the recommended setting: at or above this
--   the row reads WARN; :crit_saving_credits (default 200) the same that reads CRITICAL; :min_gaps
--   (default 20) gaps: least a row needs before it can flag; :warm_cache_pct (default 50) percent of
--   scanned bytes read from the warehouse cache at or above which the cache is worth keeping;
--   :warm_repeat_pct (default 50) percent of queries that repeat an earlier statement shape at or above
--   which the cache is worth keeping; :warm_gap_s (default 300) seconds: median gap at or below which
--   the cache is worth keeping
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. Gaps between its queries are replayed against the current
--   auto_suspend and against 60 s, 2, 5 and 10 min. idle_min_* = billed idle minutes (a gap is billed
--   up to the suspend time), suspends_* = resumes that setting would cause. est_saving_* = possible
--   saving versus now (an estimate capped at the metered idle credits, part of the idle waste, never
--   added to it). gaps, median_gap_s and
--   longest_gap_min describe the gaps between queries. resume_p50_s / p95_s = how long a resume took, from
--   its STARTED event to the COMPLETED or WAREHOUSE_CONSISTENT event (WAREHOUSE_EVENTS_HISTORY);
--   resume_wait_p50_s / p95_s = time queries waited for the warehouse to resume or provision
--   (queued_provisioning_time). manual_resizes = RESIZE_WAREHOUSE events; dml_exec_pct = share of
--   execution time in DELETE, UPDATE and MERGE. cache_pct_weighted = share of scanned
--   bytes read from the warehouse cache, which a suspend empties; repeat_share_pct = queries that repeat
--   an earlier statement shape; result_cache_pct = queries answered with no scan (result cache, kept
--   through a suspend). keep_warm = keep_warm when the cache is worth a longer setting, else
--   suspend_sooner. recommended_auto_suspend_s is 300 for keep_warm, 60 otherwise, and is empty when
--   the current setting is already that short or the row is NOT_ASSESSED. est_saving_usd_list is the
--   saving at that setting.
-- healthy: status = OK when the recommended setting saves under warn_saving_credits
-- investigate_if: WARN when the saving at the recommended setting >= warn_saving_credits; CRITICAL when
--   >= crit_saving_credits; auto_suspend 0 or NULL (never suspends) bills every gap in full
-- actions: 1) ALTER WAREHOUSE ... SET AUTO_SUSPEND = recommended_auto_suspend_s (config); 2) keep 300 s
--   or more where keep_warm says the warehouse cache is reused (config); 3) where resumes are frequent
--   and resume_wait_p95_s is high, group the work into fewer runs (config)
-- next: none
-- caveats: one cluster assumed, so multi-cluster warehouses are understated. Each resume bills at least
--   60 s; with a setting of 60 s or more every resume already stays up that long, so the minimum adds
--   nothing, and a current setting under 60 s is replayed as 60 s. Each extra resume drops the warehouse
--   cache and can make the next queries wait. Gaps are measured between query end and next query start.
--   A result-cache hit is approximate (a successful SELECT that scanned no bytes and no partitions).
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
base AS (
  SELECT warehouse_name, start_time, end_time, execution_time, query_type, execution_status,
         query_parameterized_hash, COALESCE(bytes_scanned, 0) AS bytes_scanned,
         COALESCE(partitions_total, 0) AS partitions_total,
         -- documented as 0 to 1; capped so a stray percent-scale value cannot read over 100%
         LEAST(percentage_scanned_from_cache, 1) AS percentage_scanned_from_cache, COALESCE(queued_provisioning_time, 0) AS queued_provisioning_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
),
q AS (
  SELECT warehouse_name, start_time,
         -- the latest end of any earlier query, so overlapping queries count as one busy stretch
         MAX(end_time) OVER (PARTITION BY warehouse_name ORDER BY start_time, end_time
                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_end
  FROM base
  WHERE execution_time > 0
),
gaps AS (
  SELECT warehouse_name, DATEDIFF(millisecond, prev_end, start_time) / 1000 AS gap_s
  FROM q
  WHERE prev_end IS NOT NULL AND start_time > prev_end
),
qs AS (
  -- per-warehouse shape of the work: resume wait, cache reuse, repeats; aggregated, never stored per query
  SELECT warehouse_name,
         COUNT(*) AS queries,
         COUNT_IF(queued_provisioning_time > 0) AS resume_waits,
         APPROX_PERCENTILE(IFF(queued_provisioning_time > 0, queued_provisioning_time, NULL), 0.5) / 1000 AS resume_wait_p50_s,
         APPROX_PERCENTILE(IFF(queued_provisioning_time > 0, queued_provisioning_time, NULL), 0.95) / 1000 AS resume_wait_p95_s,
         COUNT_IF(bytes_scanned > 0) AS scanned_queries,
         100 * SUM(IFF(bytes_scanned > 0, percentage_scanned_from_cache * bytes_scanned, 0))
           / NULLIF(SUM(IFF(bytes_scanned > 0 AND percentage_scanned_from_cache IS NOT NULL, bytes_scanned, 0)), 0) AS cache_pct_weighted,
         100 * (1 - COUNT(DISTINCT query_parameterized_hash) / NULLIF(COUNT(query_parameterized_hash), 0)) AS repeat_share_pct,
         100 * COUNT_IF(query_type = 'SELECT' AND execution_status = 'SUCCESS' AND bytes_scanned = 0 AND partitions_total = 0)
           / NULLIF(COUNT_IF(query_type = 'SELECT'), 0) AS result_cache_pct,
         -- Gen2 speeds up delete, update and merge: their share of execution time
         100 * SUM(IFF(query_type IN ('DELETE', 'UPDATE', 'MERGE'), execution_time, 0)) / NULLIF(SUM(execution_time), 0) AS dml_exec_pct
  FROM base
  GROUP BY 1
),
ev AS (
  -- one action writes a STARTED and a COMPLETED row; the larger of the two counts is the action count
  SELECT warehouse_name,
         COUNT_IF(event_name = 'RESUME_WAREHOUSE' AND COALESCE(event_state, 'COMPLETED') <> 'STARTED') AS observed_resumes,
         COUNT_IF(event_name = 'SUSPEND_WAREHOUSE' AND COALESCE(event_state, 'COMPLETED') <> 'STARTED') AS observed_suspends,
         GREATEST(COUNT_IF(event_name = 'RESIZE_WAREHOUSE' AND event_state = 'STARTED'),
                  COUNT_IF(event_name = 'RESIZE_WAREHOUSE' AND COALESCE(event_state, 'COMPLETED') <> 'STARTED')) AS manual_resizes
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
  GROUP BY 1
),
rs AS (
  -- a resume's own time: its STARTED row to the next COMPLETED or WAREHOUSE_CONSISTENT row
  SELECT warehouse_name, event_name, event_state, timestamp,
         LEAD(timestamp) OVER (PARTITION BY warehouse_name ORDER BY timestamp, IFF(event_state = 'STARTED', 0, 1)) AS next_ts,
         LEAD(event_state) OVER (PARTITION BY warehouse_name ORDER BY timestamp, IFF(event_state = 'STARTED', 0, 1)) AS next_state
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
    AND event_name IN ('RESUME_WAREHOUSE', 'WAREHOUSE_CONSISTENT')
),
rt AS (
  SELECT warehouse_name, COUNT(*) AS timed_resumes,
         APPROX_PERCENTILE(DATEDIFF(millisecond, timestamp, next_ts) / 1000, 0.5) AS resume_p50_s,
         APPROX_PERCENTILE(DATEDIFF(millisecond, timestamp, next_ts) / 1000, 0.95) AS resume_p95_s
  FROM rs
  WHERE event_name = 'RESUME_WAREHOUSE' AND event_state = 'STARTED'
    AND COALESCE(next_state, 'STARTED') <> 'STARTED' AND next_ts <= DATEADD(minute, 10, timestamp)
  GROUP BY 1
),
cfg AS (
  -- a setting under 60 s is replayed as 60 s: each resume bills at least 60 s anyway
  SELECT c.*, IFF(COALESCE(c.auto_stop_minutes, 0) = 0, NULL, GREATEST(c.auto_stop_minutes * 60, 60)) AS cur_s
  FROM warehouse_config c
),
sim AS (
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_size, c.warehouse_type, c.warehouse_generation,
         c.credits_per_hour, CAST(c.max_clusters AS INTEGER) AS max_clusters,
         CAST(c.auto_stop_minutes * 60 AS INTEGER) AS auto_suspend_s, c.cur_s,
         COUNT(g.gap_s) AS gaps,
         MEDIAN(g.gap_s) AS median_gap_s,
         MAX(g.gap_s) / 60 AS longest_gap_min,
         -- auto_suspend 0 or NULL never suspends, so the whole gap is billed
         SUM(IFF(c.cur_s IS NULL, g.gap_s, LEAST(g.gap_s, c.cur_s))) / 60 AS idle_min_now,
         COUNT_IF(c.cur_s IS NOT NULL AND g.gap_s > c.cur_s) AS suspends_now,
         SUM(LEAST(g.gap_s, 60)) / 60 AS idle_min_60s,
         COUNT_IF(g.gap_s > 60) AS suspends_60s,
         SUM(LEAST(g.gap_s, 120)) / 60 AS idle_min_120s,
         COUNT_IF(g.gap_s > 120) AS suspends_120s,
         SUM(LEAST(g.gap_s, 300)) / 60 AS idle_min_300s,
         COUNT_IF(g.gap_s > 300) AS suspends_300s,
         SUM(LEAST(g.gap_s, 600)) / 60 AS idle_min_600s,
         COUNT_IF(g.gap_s > 600) AS suspends_600s
  FROM cfg c
  LEFT JOIN gaps g ON g.warehouse_name = c.warehouse_name
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
),
m AS (
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits,
         -- idle as sf_wh_idle_minutes counts it (settled hours with a query split); NULL on adaptive, then compute caps
         IFF(COUNT_IF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL) = 0, NULL,
             GREATEST(SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL, credits_used_compute, 0))
                      - SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_attributed_compute_queries, 0)), 0)) AS idle_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
s AS (
  -- A saving is a replay estimate, so it is capped at the warehouse's metered idle credits (part of the idle waste).
  SELECT sim.*, e.observed_resumes, e.observed_suspends, COALESCE(e.manual_resizes, 0) AS manual_resizes,
         rt.timed_resumes, rt.resume_p50_s, rt.resume_p95_s, qs.queries, qs.resume_waits, qs.resume_wait_p50_s, qs.resume_wait_p95_s, qs.scanned_queries,
         qs.cache_pct_weighted, qs.repeat_share_pct, qs.result_cache_pct, qs.dml_exec_pct,
         COALESCE(m.compute_credits, 0) AS compute_credits,
         COALESCE(m.idle_credits, m.compute_credits, 0) AS idle_cap_credits,
         LEAST(GREATEST(idle_min_now - idle_min_60s, 0) / 60 * credits_per_hour, COALESCE(m.idle_credits, m.compute_credits, 0)) AS saving_credits_60s,
         LEAST(GREATEST(idle_min_now - idle_min_120s, 0) / 60 * credits_per_hour, COALESCE(m.idle_credits, m.compute_credits, 0)) AS saving_credits_120s,
         LEAST(GREATEST(idle_min_now - idle_min_300s, 0) / 60 * credits_per_hour, COALESCE(m.idle_credits, m.compute_credits, 0)) AS saving_credits_300s,
         LEAST(GREATEST(idle_min_now - idle_min_600s, 0) / 60 * credits_per_hour, COALESCE(m.idle_credits, m.compute_credits, 0)) AS saving_credits_600s,
         CASE WHEN qs.scanned_queries IS NULL OR qs.scanned_queries < :min_gaps OR qs.cache_pct_weighted IS NULL THEN NULL
              WHEN qs.cache_pct_weighted >= :warm_cache_pct AND qs.repeat_share_pct >= :warm_repeat_pct
                   AND median_gap_s <= :warm_gap_s THEN 'keep_warm'
              ELSE 'suspend_sooner' END AS keep_warm
  FROM sim LEFT JOIN ev e ON e.warehouse_name = sim.warehouse_name
  LEFT JOIN qs ON qs.warehouse_name = sim.warehouse_name
  LEFT JOIN rt ON rt.warehouse_name = sim.warehouse_name
  LEFT JOIN m ON m.warehouse_name = sim.warehouse_name
),
r AS (
  SELECT s.*,
         -- an unjudged warehouse gets no recommendation
         IFF(credits_per_hour IS NULL OR gaps < :min_gaps, NULL,
             IFF(cur_s IS NULL OR cur_s > IFF(keep_warm = 'keep_warm', 300, 60), IFF(keep_warm = 'keep_warm', 300, 60), NULL)) AS recommended_auto_suspend_s
  FROM s
),
f AS (
  SELECT r.*, IFF(credits_per_hour IS NULL OR gaps < :min_gaps, NULL,
                   COALESCE(IFF(recommended_auto_suspend_s = 60, saving_credits_60s,
                                IFF(recommended_auto_suspend_s = 300, saving_credits_300s, NULL)), 0)) AS saving_credits_rec
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, COALESCE(warehouse_type, 'STANDARD') AS warehouse_type, warehouse_generation,
       max_clusters, credits_per_hour, auto_suspend_s, gaps, median_gap_s, longest_gap_min,
       idle_min_now, suspends_now, idle_min_60s, suspends_60s, idle_min_120s, suspends_120s,
       idle_min_300s, suspends_300s, idle_min_600s, suspends_600s,
       observed_resumes, observed_suspends, manual_resizes, timed_resumes, resume_p50_s, resume_p95_s,
       resume_waits, resume_wait_p50_s, resume_wait_p95_s,
       ROUND(cache_pct_weighted, 1) AS cache_pct_weighted, ROUND(repeat_share_pct, 1) AS repeat_share_pct,
       ROUND(result_cache_pct, 1) AS result_cache_pct, ROUND(dml_exec_pct, 1) AS dml_exec_pct, keep_warm,
       LEAST(idle_min_now / 60 * credits_per_hour, idle_cap_credits) AS idle_credits_now,
       saving_credits_60s AS est_saving_credits_60s,
       saving_credits_60s * __CREDIT_PRICE__ AS est_saving_60s_usd_list,
       saving_credits_120s AS est_saving_credits_120s,
       saving_credits_120s * __CREDIT_PRICE__ AS est_saving_120s_usd_list,
       saving_credits_300s AS est_saving_credits_300s,
       saving_credits_300s * __CREDIT_PRICE__ AS est_saving_300s_usd_list,
       saving_credits_600s AS est_saving_credits_600s,
       saving_credits_600s * __CREDIT_PRICE__ AS est_saving_600s_usd_list,
       recommended_auto_suspend_s,
       saving_credits_rec AS est_saving_credits,
       saving_credits_rec * __CREDIT_PRICE__ AS est_saving_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN credits_per_hour IS NULL THEN 'unknown_size'
            WHEN gaps < :min_gaps THEN 'too_few_gaps' END AS not_assessed_reason,
       CASE
         WHEN credits_per_hour IS NULL OR gaps < :min_gaps THEN 'NOT_ASSESSED'
         WHEN saving_credits_rec >= :crit_saving_credits THEN 'CRITICAL'
         WHEN saving_credits_rec >= :warn_saving_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY est_saving_credits DESC NULLS LAST, warehouse_name
