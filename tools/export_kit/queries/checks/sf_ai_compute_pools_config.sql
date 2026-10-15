-- query_id: sf_ai_compute_pools_config
-- title: Compute pool settings next to what each pool spent, notebook pools included
-- domain: serving_ai   tier: standard
-- entity: compute pools = compute_pool_name
-- windowed: yes
-- money: est_current_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.COMPUTE_POOLS, SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_credits (default 20) credits: least a pool needs before it can flag; :crit_credits
--   (default 200) credits: a pool that never auto-suspends and spent this much reads CRITICAL;
--   :max_suspend_secs (default 3600) seconds: an auto-suspend longer than this flags;
--   :warn_always_on_pct (default 90) percent: hours with credits at or above this share of the window flag
-- empty_if: no_activity, view_missing
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That notebook container runtime spend appears in
--   SNOWPARK_CONTAINER_SERVICES_HISTORY under the SYSTEM_COMPUTE_POOL_* pools is not stated in the docs.
-- read_this: one row = one compute pool. The settings (min and max nodes, auto-suspend, instance family)
--   come from COMPUTE_POOLS; current_credits and active_hours from the hourly history. pool_kind is
--   system_notebook for the SYSTEM_COMPUTE_POOL_CPU and _GPU pools notebooks on container runtime use,
--   application for a pool an app owns, user for the rest. always_on_pct = active_hours / hours in the window.
-- healthy: status = OK when a pool suspends soon after use and its nodes are not held up.
-- investigate_if: WARN when a pool spending at least :min_credits never auto-suspends (AUTO_SUSPEND_SECS = 0),
--   suspends after more than :max_suspend_secs, keeps more than 1 minimum node, or is up :warn_always_on_pct
--   percent of the time; CRITICAL when it never auto-suspends and spent at least :crit_credits.
-- actions: 1) set AUTO_SUSPEND_SECS to a few minutes on pools that serve no live traffic (config);
--   2) lower MIN_NODES to 1 or 0 and pick a smaller INSTANCE_FAMILY (config); 3) drop pools nothing uses
--   (free)
-- next: sf_ai_snowpark_container_services
-- caveats: The credits are the pool's, the same figure the Snowpark Container Services spend check shows;
--   it is not extra spend. A pool that serves live traffic may need to stay up. Notebooks on container
--   runtime also use a warehouse for SQL, which is billed on the warehouse pages. A pool dropped in the
--   window keeps its spend row with no settings.
WITH cfg AS (
  SELECT cp.name AS compute_pool_name, cp.id AS compute_pool_id, cp.is_suspended, cp.min_nodes, cp.max_nodes,
         cp.instance_family, cp.auto_suspend_secs, cp.auto_resume, cp.last_resumed, cp.created, cp.owner,
         cp.application_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.COMPUTE_POOLS cp
  WHERE cp.deleted IS NULL
),
h AS (
  SELECT compute_pool_name, SUM(credits_used) AS cur_credits,
         COUNT(DISTINCT IFF(credits_used > 0, DATE_TRUNC('hour', start_time), NULL)) AS active_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
j AS (
  SELECT COALESCE(c.compute_pool_name, h.compute_pool_name) AS compute_pool_name, c.compute_pool_id,
         c.compute_pool_name IS NOT NULL AS has_config, c.is_suspended, c.min_nodes, c.max_nodes,
         c.instance_family, c.auto_suspend_secs, c.auto_resume, c.last_resumed, c.created, c.owner,
         c.application_name, COALESCE(h.cur_credits, 0) AS cur_credits, COALESCE(h.active_hours, 0) AS active_hours,
         100 * COALESCE(h.active_hours, 0) / (24 * :period_days) AS always_on_pct
  FROM cfg c
  FULL OUTER JOIN h ON UPPER(h.compute_pool_name) = UPPER(c.compute_pool_name)
),
s AS (
  SELECT j.*,
         CASE WHEN LEFT(UPPER(compute_pool_name), 20) = 'SYSTEM_COMPUTE_POOL_' THEN 'system_notebook'
              WHEN application_name IS NOT NULL THEN 'application' ELSE 'user' END AS pool_kind,
         COALESCE(auto_suspend_secs = 0, FALSE) AS never_suspends,
         COALESCE(auto_suspend_secs > :max_suspend_secs, FALSE) AS long_suspend,
         COALESCE(min_nodes > 1, FALSE) AS holds_nodes,
         always_on_pct >= :warn_always_on_pct AS always_on
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, compute_pool_name, compute_pool_id, pool_kind,
       application_name, instance_family, min_nodes, max_nodes, auto_suspend_secs, auto_resume, is_suspended,
       last_resumed, created, owner, active_hours, always_on_pct, cur_credits AS current_credits,
       cur_credits * __CREDIT_PRICE__ AS est_current_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(never_suspends, 'never auto-suspends', NULL),
         IFF(long_suspend, 'auto-suspend after ' || auto_suspend_secs || ' s', NULL),
         IFF(holds_nodes, 'holds ' || min_nodes || ' minimum nodes', NULL),
         IFF(always_on, 'up ' || ROUND(always_on_pct, 0) || '% of the window', NULL),
         IFF(NOT has_config, 'no longer listed in COMPUTE_POOLS (dropped?)', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN cur_credits < :min_credits THEN 'OK'
         WHEN never_suspends AND cur_credits >= :crit_credits THEN 'CRITICAL'
         WHEN never_suspends OR long_suspend OR holds_nodes OR always_on THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY current_credits DESC, compute_pool_name
