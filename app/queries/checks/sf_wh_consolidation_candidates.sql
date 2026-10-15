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
WITH __INCLUDE_warehouse_config__,
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
