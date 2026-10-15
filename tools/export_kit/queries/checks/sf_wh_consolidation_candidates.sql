-- query_id: sf_wh_consolidation_candidates
-- title: Same-size warehouses lightly loaded at the same hours
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :max_hour_load (default 0.5) hour load: limit above which the row flags; :max_combined_load
--   (default 1) combined load: limit above which the row flags; :warn_shared_hours (default 50) shared
--   hours: at or above this the row reads WARN; :warn_saving_credits (default 20) saving credits: at or
--   above this the row reads WARN; :crit_saving_credits (default 200) saving credits: at or above this
--   the row reads CRITICAL
-- not_assessed_reasons: not_in_show: the warehouse billed compute but SHOW WAREHOUSES does not list it
--   (dropped, or the role cannot see it), so its size and rate are unknown; unknown_size: the warehouse
--   has no fixed hourly rate (adaptive), so it cannot be paired
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. shared_hours = billed hours in which it and at least one other
--   warehouse of the same size, type and hourly rate were both running under max_hour_load queries on average, and all of
--   them together stayed under max_combined_load, so one warehouse could have served them. partners =
--   those other warehouses. est_saving_credits = its share of what running one instead of n saves: the hour's credits
--   minus the largest one, split in proportion to each warehouse's credits.
-- healthy: status = OK when shared low-load hours are few or the saving is under warn_saving_credits
-- investigate_if: WARN when shared_hours >= warn_shared_hours and the saving >= warn_saving_credits;
--   CRITICAL when the saving >= crit_saving_credits
-- actions: 1) point the lighter workloads at one of the partners and drop or suspend the others
--   (config); 2) keep chargeback by setting QUERY_TAG per workload instead of a warehouse per team
--   (free)
-- next: none
-- caveats: load counts queries, not CPU or memory. Separate warehouses may be deliberate (isolation,
--   different owners, resource monitors). Only warehouses SHOW WAREHOUSES lists are compared, at their
--   current size; other metered warehouses read NOT_ASSESSED.
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
ld AS (
  SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_start,
         SUM(avg_running * DATEDIFF(second, start_time, end_time)) / 3600 AS running_load
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
low AS (
  SELECT m.warehouse_name, m.start_time AS hour_start, m.credits_used_compute AS credits,
         COALESCE(l.running_load, 0) AS running_load,
         -- partners must bill at the same rate: same size, type (Snowpark, Gen2...) and credits per hour
         c.warehouse_size || '|' || COALESCE(c.warehouse_type, '') || '|' || TO_VARCHAR(c.credits_per_hour) AS pool
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
  JOIN warehouse_config c ON c.warehouse_name = m.warehouse_name
  LEFT JOIN ld l ON l.warehouse_name = m.warehouse_name AND l.hour_start = m.start_time
  WHERE m.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND m.start_time < __AS_OF_DATE__
    AND m.credits_used_compute > 0
    AND c.credits_per_hour IS NOT NULL
    AND COALESCE(l.running_load, 0) < :max_hour_load
),
grp AS (
  -- hours where two or more same-rate warehouses were all lightly loaded and would fit on one
  SELECT pool, hour_start, COUNT(*) AS n_up
  FROM low
  GROUP BY 1, 2
  HAVING COUNT(*) >= 2 AND SUM(running_load) < :max_combined_load
),
shared AS (
  -- The warehouse kept still bills its own hour, so the group saves the hour's credits minus the largest
  -- one; each member gets that saving in proportion to its own credits (the parts add up to it).
  SELECT l.warehouse_name, l.pool, l.hour_start, l.credits, g.n_up,
         l.credits * GREATEST(SUM(l.credits) OVER (PARTITION BY l.pool, l.hour_start)
                              - MAX(l.credits) OVER (PARTITION BY l.pool, l.hour_start), 0)
           / NULLIF(SUM(l.credits) OVER (PARTITION BY l.pool, l.hour_start), 0) AS saving_credits
  FROM low l JOIN grp g ON g.pool = l.pool AND g.hour_start = l.hour_start
),
partners AS (
  SELECT a.warehouse_name,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT b.warehouse_name), 0, 10), ', ') AS partners
  FROM shared a
  JOIN shared b ON b.hour_start = a.hour_start AND b.pool = a.pool
                AND b.warehouse_name <> a.warehouse_name
  GROUP BY 1
),
w AS (
  SELECT warehouse_name, COUNT(*) AS shared_hours, SUM(credits) AS shared_credits,
         SUM(saving_credits) AS est_saving_credits, MAX(n_up) AS max_warehouses_together
  FROM shared
  GROUP BY 1
),
tot AS (
  SELECT warehouse_name, MAX(warehouse_id) AS warehouse_id, SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
res AS (
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_size, t.compute_credits, w.shared_hours,
         w.max_warehouses_together, p.partners, w.shared_credits, w.est_saving_credits,
         CAST(NULL AS VARCHAR) AS not_assessed_reason
  FROM w
  JOIN warehouse_config c ON c.warehouse_name = w.warehouse_name
  LEFT JOIN partners p ON p.warehouse_name = w.warehouse_name
  LEFT JOIN tot t ON t.warehouse_name = w.warehouse_name
  UNION ALL
  -- metered warehouses that cannot be paired stay visible; compute > 0 keeps out CLOUD_SERVICES_ONLY
  SELECT COALESCE(c.warehouse_id, TO_VARCHAR(t.warehouse_id)), t.warehouse_name, c.warehouse_size,
         t.compute_credits, NULL, NULL, NULL, NULL, NULL,
         IFF(c.warehouse_name IS NULL, 'not_in_show', 'unknown_size')
  FROM tot t
  LEFT JOIN warehouse_config c ON c.warehouse_name = t.warehouse_name
  WHERE t.compute_credits > 0 AND (c.warehouse_name IS NULL OR c.credits_per_hour IS NULL)
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, compute_credits, shared_hours, max_warehouses_together, partners,
       shared_credits, est_saving_credits, est_saving_credits * __CREDIT_PRICE__ AS est_saving_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       not_assessed_reason,
       CASE
         WHEN not_assessed_reason IS NOT NULL THEN 'NOT_ASSESSED'
         WHEN est_saving_credits >= :crit_saving_credits THEN 'CRITICAL'
         WHEN shared_hours >= :warn_shared_hours AND est_saving_credits >= :warn_saving_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM res
ORDER BY est_saving_credits DESC NULLS LAST, warehouse_name
