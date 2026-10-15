-- query_id: sf_obj_streamlit_notebooks
-- shims: METERING_DAILY_HISTORY, WAREHOUSE_METERING_HISTORY, GRANTS_TO_ROLES
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY, SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role)
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule; warehouse credits for 6 months at most; adaptive warehouses left out; the warehouse name stands in for its id; no per-query attribution; current grants to account and database roles; no inherited or future grants
-- needs: MONITOR USAGE
-- pre: SHOW STREAMLITS IN ACCOUNT; SHOW NOTEBOOKS IN ACCOUNT
WITH -- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM __SHIM_METERING_DAILY_HISTORY__
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
a AS (
  SELECT 'STREAMLIT' AS app_type, "database_name" AS database_name, "schema_name" AS schema_name,
         "name" AS app_name, "owner" AS app_owner, "query_warehouse" AS query_warehouse,
         CAST("created_on" AS TIMESTAMP_LTZ) AS created_on, "comment" AS comment
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-2)))
  UNION ALL
  SELECT 'NOTEBOOK', "database_name", "schema_name", "name", "owner", "query_warehouse",
         CAST("created_on" AS TIMESTAMP_LTZ), "comment"
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
),
wh AS (
  SELECT warehouse_name, SUM((credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1))) AS credits
  FROM __SHIM_WAREHOUSE_METERING_HISTORY__
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
gr AS (
  SELECT granted_on, UPPER(table_catalog || '.' || table_schema || '.' || name) AS name_key,
         LISTAGG(DISTINCT grantee_name, ', ') WITHIN GROUP (ORDER BY grantee_name) AS granted_roles,
         COUNT_IF(grantee_name = 'PUBLIC') > 0 AS public_access
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE granted_on IN ('STREAMLIT', 'NOTEBOOK') AND privilege = 'USAGE' AND deleted_on IS NULL
  GROUP BY 1, 2
),
j AS (
  SELECT a.*, a.database_name || '.' || a.schema_name || '.' || a.app_name AS app_fqn,
         COUNT(*) OVER (PARTITION BY a.query_warehouse) AS apps_on_warehouse,
         COALESCE(wh.credits, 0) AS warehouse_credits,
         gr.granted_roles, COALESCE(gr.public_access, FALSE) AS public_access,
         UPPER(a.app_owner) IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN') AS admin_owner,
         UPPER(a.app_owner) IN ('SYSADMIN', 'USERADMIN') AS system_owner
  FROM a
  LEFT JOIN wh ON wh.warehouse_name = a.query_warehouse
  LEFT JOIN gr ON gr.granted_on = a.app_type
             AND gr.name_key = UPPER(a.database_name || '.' || a.schema_name || '.' || a.app_name)
),
scored AS (
  SELECT j.*, warehouse_credits * __CREDIT_PRICE__ AS usd FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       app_type, app_fqn, app_name, database_name, schema_name, app_owner, created_on, comment,
       query_warehouse, apps_on_warehouse, warehouse_credits, granted_roles, public_access,
       usd AS est_warehouse_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(admin_owner OR system_owner, 'runs as ' || app_owner || ' for every viewer', NULL),
         IFF(public_access, 'PUBLIC has USAGE', NULL),
         IFF(usd >= :warn_usd, 'its warehouse spent ' || ROUND(usd) || ' USD', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN admin_owner THEN 'CRITICAL'
         WHEN system_owner OR public_access OR usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, warehouse_credits DESC
