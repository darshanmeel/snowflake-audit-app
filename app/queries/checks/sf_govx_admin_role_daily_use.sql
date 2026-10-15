-- query_id: sf_govx_admin_role_daily_use
-- title: Everyday data work run under admin roles
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_queries (default 20) queries: at or above this the row reads WARN; :crit_queries
--   (default 500) queries: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user x admin role (ACCOUNTADMIN, SECURITYADMIN, USERADMIN, ORGADMIN,
--   SYSADMIN) x kind of work, for successful queries in the window run with that role as the primary
--   role. work_kind is DATA_READ (SELECT), DATA_WRITE (DML, COPY, unload, CTAS), OBJECT_DDL (creating
--   or changing data objects), ACCESS_ADMIN (users, roles, grants, policies, account), or OTHER (SHOW,
--   DESCRIBE, USE, CALL ...).
-- healthy: status = OK for access administration under SECURITYADMIN / USERADMIN / ACCOUNTADMIN, object
--   DDL under SYSADMIN, and metadata commands.
-- investigate_if: WARN when a user runs :warn_queries+ data reads, writes or object DDL under
--   ACCOUNTADMIN, SECURITYADMIN, USERADMIN or ORGADMIN, or SYSADMIN is used for :warn_queries+ data
--   reads and writes; CRITICAL at :crit_queries+ such queries under ACCOUNTADMIN / SECURITYADMIN /
--   ORGADMIN, or when a SERVICE user does data work under them (a pipeline running with full admin
--   rights).
-- actions: 1) give each person a functional role for data work and keep admin roles for administration
--   (free); 2) change service users' DEFAULT_ROLE to a pipeline role and revoke the admin role (free);
--   3) SET DEFAULT_ROLE to a non-admin role for admin holders (free)
-- next: none
-- caveats: queries through secondary roles show only the primary role; access administration itself is
--   covered by sf_sec_security_config_changes. QUERY_HISTORY lags up to 45 minutes.
WITH q AS (
  SELECT user_name, role_name, query_type, warehouse_name, start_time, total_elapsed_time,
         CASE
           WHEN query_type = 'SELECT' THEN 'DATA_READ'
           WHEN query_type IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE', 'COPY', 'UNLOAD', 'TRUNCATE_TABLE',
                               'CREATE_TABLE_AS_SELECT', 'MULTI_TABLE_INSERT', 'GET_FILES', 'PUT_FILES') THEN 'DATA_WRITE'
           WHEN REGEXP_LIKE(query_type, '(CREATE|ALTER|DROP)_(USER|ROLE)|GRANT|REVOKE|ALTER_ACCOUNT|.*POLICY.*|.*INTEGRATION.*|.*NETWORK.*')
             THEN 'ACCESS_ADMIN'
           WHEN REGEXP_LIKE(query_type, '(CREATE|ALTER|DROP|RENAME|UNDROP|RESTORE).*') THEN 'OBJECT_DDL'
           ELSE 'OTHER'
         END AS work_kind
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND execution_status = 'SUCCESS'
    AND role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'ORGADMIN', 'SYSADMIN')
),
u AS (
  SELECT name AS user_name, TO_VARCHAR(user_id) AS user_id, COALESCE(UPPER(type), 'PERSON') AS user_type,
         UPPER(default_role) AS default_role
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL
),
agg AS (
  SELECT user_name, role_name, work_kind, COUNT(*) AS queries, COUNT(DISTINCT DATE(start_time)) AS active_days,
         ROUND(SUM(total_elapsed_time) / 3600000, 2) AS elapsed_hours,
         LISTAGG(DISTINCT warehouse_name, ', ') AS warehouses,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT query_type) WITHIN GROUP (ORDER BY query_type), 0, 10), ', ') AS query_types,
         MAX(start_time) AS last_query
  FROM q
  GROUP BY 1, 2, 3
),
j AS (
  SELECT a.*, u.user_id, COALESCE(u.user_type, 'PERSON') AS user_type, u.default_role,
         a.work_kind IN ('DATA_READ', 'DATA_WRITE', 'OBJECT_DDL') AS is_data_work,
         a.role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN') AS is_top_admin
  FROM agg a LEFT JOIN u ON u.user_name = a.user_name
),
s AS (
  SELECT j.*,
         CASE
           WHEN is_data_work AND is_top_admin AND (queries >= :crit_queries OR user_type LIKE '%SERVICE%') THEN 'CRITICAL'
           WHEN is_data_work AND role_name <> 'SYSADMIN' AND queries >= :warn_queries THEN 'WARN'
           WHEN work_kind IN ('DATA_READ', 'DATA_WRITE') AND role_name = 'SYSADMIN' AND queries >= :warn_queries THEN 'WARN'
           ELSE 'OK'
         END AS status
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_id, user_name, user_type, default_role,
       role_name, work_kind, queries, active_days, elapsed_hours, warehouses, query_types, last_query,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(is_data_work, queries || ' ' || LOWER(REPLACE(work_kind, '_', ' ')) || ' queries under ' || role_name, NULL),
         IFF(user_type LIKE '%SERVICE%' AND is_data_work, 'service user working under an admin role', NULL),
         IFF(default_role = role_name, 'admin role is the default role', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, queries DESC
