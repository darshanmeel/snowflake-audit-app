-- query_id: sf_dt_cost
-- title: What each dynamic table's refreshes cost
-- domain: jobs_pipelines   tier: standard
-- money: est_dt_usd_list
-- entity: dynamic tables = dt_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 50) usd: at or above this the row reads WARN; :crit_usd (default 500) usd:
--   at or above this the row reads CRITICAL; :warn_growth_pct (default 50) growth pct: at or above this
--   the row reads WARN; :min_growth_usd (default 10) growth usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one dynamic table. credits are the warehouse credits Snowflake attributed to its
--   refresh queries (matched by the query_id in the refresh history), split into full and incremental
--   refreshes; prev_* is the same-length window before. est_usd_per_refresh shows what one
--   data-changing refresh costs.
-- healthy: status = OK when refreshes cost under warn_usd and did not grow by warn_growth_pct.
-- investigate_if: WARN when est_dt_usd_list >= warn_usd, or it grew >= warn_growth_pct and by at least
--   min_growth_usd; CRITICAL when est_dt_usd_list >= crit_usd.
-- actions: 1) raise TARGET_LAG (or use DOWNSTREAM) so it refreshes less often (config); 2) make a
--   FULL-refresh table incremental (see sf_dt_refresh_failures_and_lag) (free); 3) move refreshes to a
--   right-sized warehouse of their own to see and cap the spend (config).
-- next: none
-- caveats: estimated from per-query attribution, so warehouse idle time and queries under ~100 ms are
--   not included; a refresh with no attributed row counts $0. Initial and manual refreshes count.
WITH -- Current table id of each live table by full name, for dynamic tables whose refresh history
-- carries names only. Dropped tables have no id here, so their rows keep the name alone.
sf_dt_dim AS (
  SELECT table_catalog || '.' || table_schema || '.' || table_name AS dt_full_name,
         MAX(TO_VARCHAR(table_id)) AS dt_id, MAX(table_owner) AS owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  GROUP BY 1
),
r AS (
  SELECT database_name || '.' || schema_name || '.' || name AS dt_full_name,
         name AS dt_name, database_name, schema_name, query_id, refresh_action,
         IFF(data_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__), 'current', 'previous') AS period
  FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
  WHERE data_timestamp >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND data_timestamp < __AS_OF_DATE__
    AND query_id IS NOT NULL
),
attr AS (
  SELECT COALESCE(root_query_id, query_id) AS refresh_query_id, MAX(warehouse_name) AS warehouse_name,
         SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND start_time < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY 1
),
t AS (
  SELECT r.dt_full_name, MAX(r.dt_name) AS dt_name, MAX(r.database_name) AS database_name,
         MAX(r.schema_name) AS schema_name, MAX(a.warehouse_name) AS warehouse_name,
         COUNT_IF(r.period = 'current') AS refreshes,
         COUNT_IF(r.period = 'current' AND r.refresh_action IN ('FULL', 'INCREMENTAL', 'REINITIALIZE')) AS data_refreshes,
         COUNT_IF(r.period = 'current' AND a.refresh_query_id IS NOT NULL) AS attributed_refreshes,
         SUM(IFF(r.period = 'current', a.credits, 0)) AS credits,
         SUM(IFF(r.period = 'current' AND r.refresh_action IN ('FULL', 'REINITIALIZE'), a.credits, 0)) AS full_credits,
         SUM(IFF(r.period = 'current' AND r.refresh_action = 'INCREMENTAL', a.credits, 0)) AS incremental_credits,
         SUM(IFF(r.period = 'current' AND r.refresh_action = 'NO_DATA', a.credits, 0)) AS no_data_credits,
         SUM(IFF(r.period = 'previous', a.credits, 0)) AS prev_credits
  FROM r LEFT JOIN attr a ON a.refresh_query_id = r.query_id
  GROUP BY r.dt_full_name
  HAVING COUNT_IF(r.period = 'current') > 0 OR SUM(IFF(r.period = 'previous', a.credits, 0)) > 0
),
scored AS (
  SELECT t.*, d.dt_id, d.owner,
         COALESCE(credits, 0) * __CREDIT_PRICE__ AS usd,
         COALESCE(prev_credits, 0) * __CREDIT_PRICE__ AS prev_usd
  FROM t LEFT JOIN sf_dt_dim d ON d.dt_full_name = t.dt_full_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       dt_full_name, dt_name, dt_id, database_name, schema_name, owner, warehouse_name,
       refreshes, data_refreshes, attributed_refreshes,
       COALESCE(credits, 0) AS credits, COALESCE(full_credits, 0) AS full_refresh_credits,
       COALESCE(incremental_credits, 0) AS incremental_refresh_credits,
       COALESCE(no_data_credits, 0) AS no_data_credits, COALESCE(prev_credits, 0) AS prev_credits,
       100 * full_credits / NULLIF(credits, 0) AS full_credit_pct,
       100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
       usd AS est_dt_usd_list, prev_usd AS est_prev_usd_list, usd - prev_usd AS est_change_usd_list,
       usd / NULLIF(data_refreshes, 0) AS est_usd_per_refresh,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(COALESCE(credits, 0), 2) || ' credits over ' || refreshes || ' refreshes ('
         || ROUND(COALESCE(100 * full_credits / NULLIF(credits, 0), 0)) || '% in full refreshes)' AS cost_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN attributed_refreshes = 0 AND refreshes > 0 THEN 'no_attributed_usage' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR (attributed_refreshes = 0 AND refreshes > 0) THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd
           OR (usd - prev_usd >= :min_growth_usd
               AND 100 * (credits - prev_credits) / NULLIF(prev_credits, 0) >= :warn_growth_pct) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY est_dt_usd_list DESC NULLS LAST, credits DESC NULLS LAST
