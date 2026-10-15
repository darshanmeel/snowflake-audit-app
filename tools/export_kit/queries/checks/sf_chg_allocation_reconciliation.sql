-- query_id: sf_chg_allocation_reconciliation
-- title: How much of the bill can be charged back, per service
-- domain: cost   tier: standard
-- entity: services = service_type
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_ALERT_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_QUALITY_MONITORING_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_unallocated_pct (default 25) unallocated pct: at or above this the row reads WARN;
--   :crit_unallocated_pct (default 50) unallocated pct: at or above this the row reads CRITICAL;
--   :min_unallocated_usd (default 100) unallocated usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one metered service type (METERING_DAILY_HISTORY), a 'CLOUD_SERVICES' row and a
--   'TOTAL' row. metered_credits = what the service used; allocated_credits = what a detail view ties
--   to a query, user or object (allocated_to says which); unallocated_credits is the rest: warehouse
--   idle and short queries for WAREHOUSE_METERING, and whole services with no per-object view
--   (allocated_to = 'none'). billed_credits is after the cloud services adjustment. AI services are
--   split by feature in sf_ai_spend_by_feature_reconciled, not here.
-- healthy: status = OK when most of each service's credits can be tied to an owner.
-- investigate_if: WARN when unallocated is >= warn_unallocated_pct of a service (and >=
--   min_unallocated_usd); CRITICAL at crit_unallocated_pct.
-- actions: 1) agree how shared remainders are split (proportional to direct use is common, see
--   sf_chg_idle_allocation) (free); 2) cut warehouse idle, the usual largest remainder (config); 3) for
--   services with no detail view, charge them to the platform team explicitly (free).
-- next: none
-- caveats: detail views lag differently (up to 3 h for metering, up to 8 h for attribution), so the
--   latest day can look unallocated. Cloud services per query are before the daily adjustment. Services
--   without an object view here (replication, AI, containers, ...) show as 'none'.
WITH m AS (
  SELECT service_type, SUM(credits_used_compute) AS compute_credits,
         SUM(credits_used_cloud_services) AS cs_credits,
         SUM(credits_adjustment_cloud_services) AS cs_adjustment
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY service_type
),
qa AS (
  SELECT SUM(credits_attributed_compute) AS compute_attr,
         SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_attr
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
det AS (
  SELECT 'WAREHOUSE_METERING' AS service_type, 'query / user (exact)' AS allocated_to, compute_attr AS credits FROM qa
  UNION ALL
  SELECT 'QUERY_ACCELERATION', 'query / user (exact)', qas_attr FROM qa
  UNION ALL
  SELECT 'AUTO_CLUSTERING', 'table', SUM(credits_used) FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'MATERIALIZED_VIEW', 'materialized view', SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used)))
  FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'SEARCH_OPTIMIZATION', 'table', SUM(credits_used) FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'SERVERLESS_TASK', 'task', SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used))) FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'PIPE', 'pipe', SUM(credits_used) FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  -- CREDITS_USED is VARCHAR in the alert view
  SELECT 'SERVERLESS_ALERTS', 'alert', SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used))) FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_ALERT_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'SNOWPARK_CONTAINER_SERVICES', 'compute pool', SUM(credits_used)
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'DATA_QUALITY_MONITORING', 'table', SUM(credits_used)
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_QUALITY_MONITORING_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  UNION ALL
  SELECT 'REPLICATION', 'replication group or database', SUM(credits)
  FROM (SELECT credits_used AS credits FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY
        WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
        UNION ALL
        SELECT credits_used FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
        WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__)
),
qcs AS (
  SELECT SUM(credits_used_cloud_services) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
svc AS (
  SELECT m.service_type, COALESCE(d.allocated_to, 'none') AS allocated_to,
         m.compute_credits AS metered_credits,
         LEAST(COALESCE(d.credits, 0), m.compute_credits) AS allocated_credits,
         -- compute is billed as metered; the cloud services adjustment is shown on its own row.
         m.compute_credits AS billed_credits
  FROM m
  LEFT JOIN det d ON d.service_type = m.service_type
  WHERE m.compute_credits > 0
),
cs AS (
  SELECT 'CLOUD_SERVICES' AS service_type, 'query / user (before adjustment)' AS allocated_to,
         SUM(m.cs_credits) AS metered_credits,
         LEAST((SELECT credits FROM qcs), SUM(m.cs_credits)) AS allocated_credits,
         GREATEST(SUM(m.cs_credits + m.cs_adjustment), 0) AS billed_credits
  FROM m
),
rows_ AS (
  SELECT service_type, allocated_to, metered_credits, billed_credits, allocated_credits FROM svc
  UNION ALL
  SELECT service_type, allocated_to, metered_credits, billed_credits, allocated_credits FROM cs
),
t AS (
  SELECT * FROM rows_
  UNION ALL
  SELECT 'TOTAL', 'all', SUM(metered_credits), SUM(billed_credits), SUM(allocated_credits) FROM rows_
),
s AS (
  SELECT t.*, GREATEST(metered_credits - allocated_credits, 0) AS unallocated_credits,
         100 * GREATEST(metered_credits - allocated_credits, 0) / NULLIF(metered_credits, 0) AS unallocated_pct
  FROM t
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, service_type, service_type = 'TOTAL' AS is_total_row, allocated_to,
       metered_credits, billed_credits, allocated_credits, unallocated_credits, unallocated_pct,
       billed_credits * __CREDIT_PRICE__ AS est_billed_usd_list,
       unallocated_credits * __CREDIT_PRICE__ AS est_unallocated_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN COALESCE(metered_credits, 0) = 0 THEN 'no_metered_credits' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR COALESCE(metered_credits, 0) = 0 THEN 'NOT_ASSESSED'
         WHEN unallocated_credits * __CREDIT_PRICE__ < :min_unallocated_usd THEN 'OK'
         WHEN unallocated_pct >= :crit_unallocated_pct THEN 'CRITICAL'
         WHEN unallocated_pct >= :warn_unallocated_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY service_type = 'TOTAL', unallocated_credits DESC NULLS LAST
