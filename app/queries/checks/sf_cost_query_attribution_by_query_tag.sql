-- query_id: sf_cost_query_attribution_by_query_tag
-- title: Warehouse spend by query tag, untagged and idle
-- domain: cost   tier: standard
-- entity: query tags = query_tag
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_untagged_pct (default 30) untagged pct: at or above this the row reads WARN;
--   :crit_untagged_pct (default 60) untagged pct: at or above this the row reads CRITICAL;
--   :warn_idle_pct (default 30) idle pct: at or above this the row reads WARN; :crit_idle_pct (default
--   50) idle pct: at or above this the row reads CRITICAL; :min_spend_usd (default 100) spend usd:
--   least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one query tag, plus '(untagged)' and '(warehouse idle)' rows. attributed_credits
--   are exact per-query compute credits (query acceleration is billed apart and shown in
--   query_acceleration_credits, outside the split); share_of_warehouse_pct is the part of all warehouse compute
--   credits in the window, so the rows add up to 100. Tagged share is the spend you can charge back by
--   tag today.
-- healthy: status = OK when most spend carries a tag and idle time stays small.
-- investigate_if: WARN when untagged spend is >= warn_untagged_pct or idle >= warn_idle_pct (and the
--   row is >= min_spend_usd); CRITICAL at crit_untagged_pct / crit_idle_pct.
-- actions: 1) look at sf_cost_query_attribution_by_user to see who runs the untagged spend (free); 2)
--   set QUERY_TAG on the users, service accounts, dbt/Airflow connections and BI tools behind it
--   (config); 3) shorten auto-suspend or consolidate warehouses where idle is high (spend).
-- next: none
-- caveats: adaptive warehouses (no query-time split) and hours newer than the 8 h attribution lag are left out of both sides, so they never read as idle; queries under about 100 ms have no attribution row. Tags are free text: variants of one
--   team's tag show as separate rows. Idle time is not attributed to any tag.
WITH t AS (
  SELECT COALESCE(NULLIF(TRIM(query_tag), ''), '(untagged)') AS query_tag,
         COUNT(*) AS queries,
         COUNT(DISTINCT user_name) AS users,
         COUNT(DISTINCT warehouse_id) AS warehouses_used,
         SUM(credits_attributed_compute) AS credits,
         SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP())
  GROUP BY 1
),
wh AS (
  SELECT SUM(IFF(credits_attributed_compute_queries IS NOT NULL AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_used_compute, 0)) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
rows_ AS (
  SELECT query_tag, IFF(query_tag = '(untagged)', 'untagged', 'tag') AS row_kind,
         queries, users, warehouses_used, credits, qas_credits
  FROM t
  UNION ALL
  SELECT '(warehouse idle)', 'idle', NULL, NULL, NULL,
         GREATEST(wh.compute_credits - (SELECT COALESCE(SUM(credits), 0) FROM t), 0), NULL
  FROM wh
),
s AS (
  SELECT r.*, 100 * r.credits / NULLIF(wh.compute_credits, 0) AS share_pct, wh.compute_credits
  FROM rows_ r CROSS JOIN wh
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, query_tag, row_kind,
       queries, users, warehouses_used, credits AS attributed_credits, qas_credits AS query_acceleration_credits,
       share_pct AS share_of_warehouse_pct, compute_credits AS warehouse_compute_credits,
       credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN COALESCE(compute_credits, 0) = 0 THEN 'no_warehouse_compute' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR COALESCE(compute_credits, 0) = 0 THEN 'NOT_ASSESSED'
         WHEN row_kind = 'tag' OR credits * __CREDIT_PRICE__ < :min_spend_usd THEN 'OK'
         WHEN row_kind = 'idle' AND share_pct >= :crit_idle_pct THEN 'CRITICAL'
         WHEN row_kind = 'idle' AND share_pct >= :warn_idle_pct THEN 'WARN'
         WHEN row_kind = 'untagged' AND share_pct >= :crit_untagged_pct THEN 'CRITICAL'
         WHEN row_kind = 'untagged' AND share_pct >= :warn_untagged_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY attributed_credits DESC NULLS LAST
