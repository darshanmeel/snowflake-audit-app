-- query_id: sf_wh_query_acceleration_spend
-- title: Query Acceleration spend per warehouse
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SHOW
--   WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_share_pct (default 25) share pct: at or above this the row reads WARN; :crit_share_pct
--   (default 75) share pct: at or above this the row reads CRITICAL; :warn_credits (default 50)
--   credits: at or above this the row reads WARN; :crit_credits (default 500) credits: at or above this
--   the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse that used the Query Acceleration Service. qas_credits = serverless
--   credits QAS billed; qas_share_pct = that against the warehouse's own compute credits.
--   accelerated_queries = queries that scanned data through QAS. max_scale_factor 0 means no cap.
-- healthy: status = OK when QAS costs under warn_share_pct of the warehouse and under warn_credits
-- investigate_if: WARN when qas_share_pct >= warn_share_pct or qas_credits >= warn_credits; the SQL marks
--   it CRITICAL when qas_share_pct >= crit_share_pct or qas_credits >= crit_credits, but the app shows
--   a spend report as WARN at most.
-- actions: 1) set QUERY_ACCELERATION_MAX_SCALE_FACTOR to a cap (0 is unlimited) (config); 2) cluster or
--   filter the tables behind the accelerated scans so fewer partitions are read (free); 3) if QAS is
--   steady rather than bursty, a larger warehouse may cost less (config)
-- next: none
-- caveats: QAS credits are billed in addition to warehouse credits. QUERY_ACCELERATION_HISTORY lags up
--   to 3 hours.
WITH __INCLUDE_warehouse_config__,
sf AS (
  SELECT s."name" AS warehouse_name,
         TRY_TO_NUMBER(TO_VARCHAR(s."query_acceleration_max_scale_factor")) AS max_scale_factor
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
),
a AS (
  SELECT warehouse_name, MAX(TO_VARCHAR(warehouse_id)) AS warehouse_id, SUM(credits_used) AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
  HAVING SUM(credits_used) > 0
),
m AS (
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
q AS (
  SELECT warehouse_name, COUNT(*) AS accelerated_queries,
         COUNT(DISTINCT query_parameterized_hash) AS accelerated_statement_shapes
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_acceleration_bytes_scanned > 0
  GROUP BY 1
),
j AS (
  SELECT a.warehouse_id, a.warehouse_name, c.warehouse_size,
         LOWER(TO_VARCHAR(c.query_acceleration)) = 'true' AS qas_enabled, sf.max_scale_factor,
         a.qas_credits, m.compute_credits,
         q.accelerated_queries, q.accelerated_statement_shapes,
         100 * a.qas_credits / NULLIF(m.compute_credits, 0) AS qas_share_pct
  FROM a
  LEFT JOIN warehouse_config c ON c.warehouse_name = a.warehouse_name
  LEFT JOIN sf ON sf.warehouse_name = a.warehouse_name
  LEFT JOIN m ON m.warehouse_name = a.warehouse_name
  LEFT JOIN q ON q.warehouse_name = a.warehouse_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, qas_enabled, CAST(max_scale_factor AS INTEGER) AS max_scale_factor,
       accelerated_queries, accelerated_statement_shapes,
       qas_credits, qas_credits * __CREDIT_PRICE__ AS est_qas_usd_list,
       compute_credits, compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list, qas_share_pct,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN qas_share_pct >= :crit_share_pct OR qas_credits >= :crit_credits THEN 'CRITICAL'
         WHEN qas_share_pct >= :warn_share_pct OR qas_credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY qas_credits DESC
