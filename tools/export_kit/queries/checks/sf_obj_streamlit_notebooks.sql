-- query_id: sf_obj_streamlit_notebooks
-- title: Streamlit apps and notebooks: owner rights, access and warehouse spend
-- domain: governance_access   tier: standard
-- entity: apps and notebooks = app_fqn
-- windowed: yes
-- pre: SHOW STREAMLITS IN ACCOUNT
-- pre: SHOW NOTEBOOKS IN ACCOUNT
-- reads: SHOW STREAMLITS IN ACCOUNT, SHOW NOTEBOOKS IN ACCOUNT,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 100) usd: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one Streamlit app or notebook. Both run with their OWNER's rights: anyone
--   granted USAGE on the app acts as the owner role inside it, so an admin owner hands admin data to
--   every viewer. granted_roles lists roles with USAGE; query_warehouse runs its queries, and
--   warehouse_credits is that warehouse's total spend in the window (shared with anything else on it);
--   apps_on_warehouse counts the apps pointing at it.
-- healthy: status = OK when a functional role owns it and access is granted to named roles.
-- investigate_if: WARN when SYSADMIN / USERADMIN owns it, PUBLIC has USAGE, or its warehouse spent >=
--   warn_usd with apps on it (an open app keeps the warehouse awake); CRITICAL when ACCOUNTADMIN,
--   SECURITYADMIN or ORGADMIN owns it.
-- actions: 1) transfer ownership to a least-privilege role made for the app (free); 2) revoke USAGE
--   from PUBLIC and grant to named roles (config); 3) give apps their own X-Small warehouse with a
--   short auto-suspend so their idle time is visible and cheap (config).
-- next: none
-- caveats: the credits are the warehouse's, not the app's: Snowflake has no per-app warehouse compute view.
--   Notebooks on container runtime use a compute pool, not query_warehouse; see sf_ai_compute_pools_config. SHOW lists what the export
--   role can see; GRANTS_TO_ROLES lags up to 2 hours.
WITH -- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
gr AS (
  SELECT granted_on, UPPER(table_catalog || '.' || table_schema || '.' || name) AS name_key,
         LISTAGG(DISTINCT grantee_name, ', ') WITHIN GROUP (ORDER BY grantee_name) AS granted_roles,
         COUNT_IF(grantee_name = 'PUBLIC') > 0 AS public_access
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
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
