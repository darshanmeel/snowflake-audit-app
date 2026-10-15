-- query_id: sf_wh_gen2_fit
-- title: Gen1 or Gen2: which warehouses to test, and whether a conversion paid off
-- domain: compute   tier: standard
-- windowed: yes
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :dml_pct (default 50) percent of run time in delete, update and merge at or above which a Gen1
--   warehouse is worth a Gen2 test (the same bar as the Gen2 hint of sf_wh_auto_suspend_tuning);
--   :min_days (default 3) days a conversion needs on each side before it can be judged;
--   :warn_cost_up_pct (default 10) percent rise in credits per query after a conversion at or above
--   which the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one standard warehouse. generation is its generation now. dml_exec_pct is the
--   share of its run time in DELETE, UPDATE and MERGE, which Gen2 runs faster (the same measure as
--   sf_wh_auto_suspend_tuning). Gen2 bills 1.35 times the Gen1 rate per hour (1.25 on Azure), so it pays
--   only when the same work finishes over a quarter sooner. converted_at is the last generation change in
--   the window (event reason CONVERT_RESOURCE_CONSTRAINT) and converted_to the generation it moved to.
--   For a conversion, before and after are the days of the window on each side (the day itself left
--   out): credits per day and per query from WAREHOUSE_METERING_HISTORY and QUERY_HISTORY, and
--   same_shape_exec_change_pct, the change in run time of the statement shapes that ran on both sides.
--   verdict: test_gen2 (a Gen1 warehouse at or over dml_pct), gen1_fits, gen2, gen2_not_offered (5X and
--   6X-Large), paid_off (credits per query fell after the move to Gen2), about_even, costs_more (rose by
--   warn_cost_up_pct or more), back_to_gen1, too_soon. Context, not a saving: no $ here.
-- healthy: status = OK unless a conversion made the same work cost more
-- investigate_if: WARN when verdict = costs_more (credits per query rose by warn_cost_up_pct or more after
--   the move to Gen2)
-- actions: 1) test Gen2 on a test_gen2 warehouse for a week: ALTER WAREHOUSE ... SET GENERATION = '2',
--   suspended first so the old and new clusters do not bill together (config); 2) for costs_more, compare
--   the busy hours, then move it back with GENERATION = '1' if the work did not speed up (config); 3)
--   after a move to Gen2, try one size down: faster runs can fit a smaller warehouse (config)
-- next: sf_wh_auto_suspend_tuning, sf_wh_oversized
-- not_assessed_reasons: too_soon: the conversion has fewer than min_days days on one side in the window;
--   no_queries: no statement ran on the warehouse in the window
-- caveats: heavy: reads QUERY_HISTORY for the window (period_days only), aggregated per warehouse, day
--   and statement shape in Snowflake. Before and after differ in more than the generation (volume,
--   data size), so the comparison is a sign, not proof; credits per query moves with the mix of work.
--   Gen2 is not offered in a few regions. Converting a running warehouse bills old and new clusters
--   until running queries end.
WITH __INCLUDE_warehouse_config__,
std AS (
  SELECT * FROM warehouse_config
  WHERE UPPER(COALESCE(warehouse_type, 'STANDARD')) = 'STANDARD'
),
conv_ev AS (
  -- the last generation change in the window
  SELECT warehouse_name, MAX(timestamp) AS ts
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
    AND event_reason = 'CONVERT_RESOURCE_CONSTRAINT'
  GROUP BY 1
),
conv AS (
  -- the constraint the warehouse settled on after it (its next WAREHOUSE_CONSISTENT row)
  SELECT e.warehouse_name, e.ts AS converted_at, c.resource_constraint AS to_constraint
  FROM conv_ev e
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY c
    ON c.warehouse_name = e.warehouse_name AND c.event_name = 'WAREHOUSE_CONSISTENT'
   AND c.resource_constraint LIKE 'STANDARD_GEN_%' AND c.timestamp >= e.ts AND c.timestamp < __AS_OF_DATE__
  QUALIFY ROW_NUMBER() OVER (PARTITION BY e.warehouse_name ORDER BY c.timestamp NULLS LAST) = 1
),
qd AS (
  -- per warehouse, day and statement shape: counts and run time only
  SELECT q.warehouse_name, CAST(q.start_time AS DATE) AS d, COALESCE(q.query_parameterized_hash, q.query_type) AS shape,
         COUNT(*) AS n, SUM(q.execution_time) AS exec_ms,
         SUM(IFF(q.query_type IN ('DELETE', 'UPDATE', 'MERGE'), q.execution_time, 0)) AS dml_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  JOIN std ON std.warehouse_name = q.warehouse_name
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
    AND q.execution_time > 0
  GROUP BY 1, 2, 3
),
qs AS (
  SELECT warehouse_name, SUM(n) AS queries, 100 * SUM(dml_ms) / NULLIF(SUM(exec_ms), 0) AS dml_exec_pct
  FROM qd GROUP BY 1
),
md AS (
  SELECT warehouse_name, CAST(start_time AS DATE) AS d, SUM(credits_used_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
fd AS (
  SELECT warehouse_name, MIN(d) AS first_day FROM md GROUP BY 1
),
side AS (
  -- before / after a conversion, its own day left out; before starts at the first billed day in the window
  SELECT c.warehouse_name, c.converted_at, c.to_constraint,
         DATEDIFF(day, GREATEST(DATEADD(day, -:period_days, __AS_OF_DATE__), COALESCE(fd.first_day, DATEADD(day, -:period_days, __AS_OF_DATE__))),
                  CAST(c.converted_at AS DATE)) AS days_before,
         DATEDIFF(day, CAST(c.converted_at AS DATE), __AS_OF_DATE__) - 1 AS days_after
  FROM conv c
  LEFT JOIN fd ON fd.warehouse_name = c.warehouse_name
),
mc AS (
  SELECT s.warehouse_name,
         SUM(IFF(md.d < CAST(s.converted_at AS DATE), md.credits, 0)) AS credits_before,
         SUM(IFF(md.d > CAST(s.converted_at AS DATE), md.credits, 0)) AS credits_after
  FROM side s JOIN md ON md.warehouse_name = s.warehouse_name
  GROUP BY 1
),
qc AS (
  SELECT s.warehouse_name,
         SUM(IFF(qd.d < CAST(s.converted_at AS DATE), qd.n, 0)) AS queries_before,
         SUM(IFF(qd.d > CAST(s.converted_at AS DATE), qd.n, 0)) AS queries_after
  FROM side s JOIN qd ON qd.warehouse_name = s.warehouse_name
  GROUP BY 1
),
sh AS (
  -- the shapes that ran on both sides: their run time after, against the same runs at the old speed
  SELECT s.warehouse_name, qd.shape,
         SUM(IFF(qd.d < CAST(s.converted_at AS DATE), qd.exec_ms, 0)) / NULLIF(SUM(IFF(qd.d < CAST(s.converted_at AS DATE), qd.n, 0)), 0) AS avg_before_ms,
         SUM(IFF(qd.d > CAST(s.converted_at AS DATE), qd.exec_ms, 0)) AS exec_after_ms,
         SUM(IFF(qd.d > CAST(s.converted_at AS DATE), qd.n, 0)) AS n_after
  FROM side s JOIN qd ON qd.warehouse_name = s.warehouse_name
  GROUP BY 1, 2
),
shc AS (
  SELECT warehouse_name, COUNT(*) AS same_shapes,
         100 * (SUM(exec_after_ms) / NULLIF(SUM(avg_before_ms * n_after), 0) - 1) AS same_shape_exec_change_pct
  FROM sh
  WHERE avg_before_ms IS NOT NULL AND n_after > 0
  GROUP BY 1
),
r AS (
  SELECT std.warehouse_id, std.warehouse_name, std.warehouse_size, std.warehouse_generation AS generation,
         std.credits_per_hour, COALESCE(qs.queries, 0) AS queries, qs.dml_exec_pct,
         s.converted_at, CASE s.to_constraint WHEN 'STANDARD_GEN_2' THEN 'GEN2' WHEN 'STANDARD_GEN_1' THEN 'GEN1' END AS converted_to,
         s.days_before, s.days_after,
         mc.credits_before / NULLIF(s.days_before, 0) AS credits_per_day_before,
         mc.credits_after / NULLIF(s.days_after, 0) AS credits_per_day_after,
         mc.credits_before / NULLIF(qc.queries_before, 0) AS credits_per_query_before,
         mc.credits_after / NULLIF(qc.queries_after, 0) AS credits_per_query_after,
         qc.queries_before, qc.queries_after, shc.same_shapes, shc.same_shape_exec_change_pct,
         UPPER(REPLACE(std.warehouse_size, '-', '')) IN ('5XLARGE', '6XLARGE', 'XXXXXLARGE', 'XXXXXXLARGE') AS too_big
  FROM std
  LEFT JOIN qs ON qs.warehouse_name = std.warehouse_name
  LEFT JOIN side s ON s.warehouse_name = std.warehouse_name
  LEFT JOIN mc ON mc.warehouse_name = std.warehouse_name
  LEFT JOIN qc ON qc.warehouse_name = std.warehouse_name
  LEFT JOIN shc ON shc.warehouse_name = std.warehouse_name
),
v AS (
  SELECT r.*,
         100 * (credits_per_query_after / NULLIF(credits_per_query_before, 0) - 1) AS credits_per_query_change_pct,
         CASE
           WHEN converted_at IS NOT NULL AND (COALESCE(days_before, 0) < :min_days OR COALESCE(days_after, 0) < :min_days
                OR credits_per_query_before IS NULL OR credits_per_query_after IS NULL) THEN 'too_soon'
           WHEN converted_to = 'GEN1' THEN 'back_to_gen1'
           WHEN converted_at IS NOT NULL AND credits_per_query_after <= credits_per_query_before THEN 'paid_off'
           WHEN converted_at IS NOT NULL
                AND 100 * (credits_per_query_after / NULLIF(credits_per_query_before, 0) - 1) >= :warn_cost_up_pct THEN 'costs_more'
           WHEN converted_at IS NOT NULL THEN 'about_even'
           WHEN queries = 0 THEN NULL
           WHEN generation = 'GEN2' THEN 'gen2'
           WHEN too_big THEN 'gen2_not_offered'
           WHEN dml_exec_pct >= :dml_pct THEN 'test_gen2'
           ELSE 'gen1_fits'
         END AS verdict
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, warehouse_size,
       generation, credits_per_hour, queries, ROUND(dml_exec_pct, 1) AS dml_exec_pct, verdict,
       converted_at, converted_to, days_before, days_after,
       credits_per_day_before, credits_per_day_after, credits_per_query_before, credits_per_query_after,
       ROUND(credits_per_query_change_pct, 1) AS credits_per_query_change_pct,
       queries_before, queries_after, same_shapes, ROUND(same_shape_exec_change_pct, 1) AS same_shape_exec_change_pct,
       CASE WHEN verdict = 'too_soon' THEN 'too_soon' WHEN queries = 0 AND converted_at IS NULL THEN 'no_queries' END AS not_assessed_reason,
       CASE
         WHEN verdict = 'too_soon' OR (queries = 0 AND converted_at IS NULL) THEN 'NOT_ASSESSED'
         WHEN verdict = 'costs_more' THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM v
ORDER BY CASE verdict WHEN 'costs_more' THEN 0 WHEN 'test_gen2' THEN 1 WHEN 'paid_off' THEN 2 WHEN 'about_even' THEN 3 ELSE 4 END,
         dml_exec_pct DESC NULLS LAST, warehouse_name
