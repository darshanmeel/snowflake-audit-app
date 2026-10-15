-- query_id: sf_wh_idle_minutes
-- title: warehouse idle minutes - compute credits that ran no query (possible waste)
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_idle_minutes (default 30) counted idle minutes in the window below which the idle share
--   alone never flags; :warn_idle_pct (default 30) percent of compute credits that ran no query that
--   flags WARN; :crit_idle_pct (default 60) the same that flags CRITICAL; :warn_waste_usd (default 20)
--   possible waste in dollars that flags WARN at any idle share; :crit_waste_usd (default 200) the same
--   that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one warehouse that ran or was billed in the window. idle_credits = compute credits
--   minus the credits Snowflake attributes to queries (WAREHOUSE_METERING_HISTORY), so it is the time the
--   warehouse was running with no query in it, including the auto-stop wait after the last query.
--   idle_minutes converts those credits at this warehouse's credits per hour for its size and generation,
--   and est_wasted_usd_list prices them. It is POSSIBLE waste: a few idle seconds between two queries are
--   normal and are part of it. Hours newer than 8 h (the attribution lag) and adaptive warehouses (no
--   attribution) are left out. waste_reason says it in one line. The gaps and the auto-suspend options
--   are in sf_wh_auto_suspend_tuning.
-- healthy: status = OK - idle is below :warn_idle_pct percent of compute credits, or below
--   :min_idle_minutes minutes in the window, and under :warn_waste_usd of possible waste (field
--   heuristic).
-- investigate_if: status = WARN or CRITICAL - at least :min_idle_minutes idle minutes and at least
--   :warn_idle_pct (WARN) or :crit_idle_pct (CRITICAL) percent of compute credits idle, or possible waste
--   at/above :warn_waste_usd (WARN) or :crit_waste_usd (CRITICAL) dollars at any share, so a large idle
--   cost on a busy warehouse is flagged too. NOT_ASSESSED is not a pass: read not_assessed_reason and
--   waste_reason.
-- actions: 1) ALTER WAREHOUSE ... SET AUTO_SUSPEND to the setting sf_wh_auto_suspend_tuning recommends
--   (60 s, or 300 s where the warehouse cache is reused) (config); 2) move sparse, bursty workloads onto one
--   shared warehouse, or schedule them together, so fewer warehouses sit up between queries (config);
--   3) find what keeps the warehouse awake between queries: polls, BI refreshes, task schedules (free)
-- next: sf_wh_auto_suspend_tuning
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced; no_compute: the warehouse billed no compute credits in the window, so idle time cannot be
--   judged; no_query_attribution: no billed hour older than 8 h has a query-time split (adaptive warehouses),
--   so idle time cannot be told from unattributed work
-- caveats: Snowflake version: idle = compute credits minus credits_attributed_compute_queries (NULL on adaptive warehouses, which are not judged; hours newer than 8 h are left out on both sides),
--   Snowflake's own split of warehouse time into query time and idle time. Minutes are estimated from
--   credits at the warehouse's current size and generation. Queries under about 100 ms are not attributed, so a very busy warehouse of tiny
--   queries reads a little more idle than it is. The 8 h lag counts back from the export time.
WITH __INCLUDE_warehouse_config__,
m AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         SUM(credits_used_compute) AS compute_credits,
         SUM(credits_attributed_compute_queries) AS query_credits,
         COUNT_IF(credits_used_compute > 0) AS billed_hours,
         -- Only hours older than the 8 h attribution lag with a non-NULL split count as idle evidence; a warehouse
         -- whose every settled billed hour is NULL (adaptive) is not judged.
         SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL, credits_used_compute, 0)) AS attributed_compute_credits,
         SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_attributed_compute_queries, 0)) AS attributed_query_credits,
         COUNT_IF(credits_used_compute > 0 AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL) AS attributed_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
j AS (
  SELECT m.*, c.warehouse_type, c.warehouse_size, c.auto_stop_minutes, c.credits_per_hour,
         IFF(m.attributed_hours > 0, GREATEST(m.attributed_compute_credits - m.attributed_query_credits, 0), NULL) AS idle_credits,
         60 * m.compute_credits / NULLIF(c.credits_per_hour, 0) AS up_minutes
  FROM m LEFT JOIN warehouse_config c ON c.warehouse_name = m.warehouse_name
),
scored AS (
  SELECT j.*,
         60 * idle_credits / NULLIF(credits_per_hour, 0) AS idle_minutes,
         100 * idle_credits / NULLIF(attributed_compute_credits, 0) AS idle_pct,
         idle_credits * __CREDIT_PRICE__ AS wasted_usd
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id,
       -- no SHOW row means the type is unknown, not STANDARD
       COALESCE(warehouse_type, 'unknown (not in SHOW)') AS warehouse_kind, warehouse_size,
       CAST(auto_stop_minutes AS INTEGER) AS auto_stop_minutes,
       up_minutes, up_minutes - idle_minutes AS busy_minutes, idle_minutes, idle_pct AS idle_share_pct,
       compute_credits AS net_credits, compute_credits * __CREDIT_PRICE__ AS est_usd_list,
       wasted_usd AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       __CREDIT_PRICE__ * credits_per_hour / 60 AS usd_per_cluster_minute,
       IFF(attributed_hours > 0, ROUND(idle_pct) || '% of compute credits ran no query', NULL) AS waste_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN compute_credits = 0 THEN 'no_compute'
            WHEN attributed_hours = 0 THEN 'no_query_attribution' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR compute_credits = 0 OR attributed_hours = 0 THEN 'NOT_ASSESSED'
         WHEN wasted_usd >= :crit_waste_usd
           OR (idle_minutes >= :min_idle_minutes AND idle_pct >= :crit_idle_pct) THEN 'CRITICAL'
         WHEN wasted_usd >= :warn_waste_usd
           OR (idle_minutes >= :min_idle_minutes AND idle_pct >= :warn_idle_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY est_wasted_usd_list DESC NULLS LAST
