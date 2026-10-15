-- query_id: sf_sec_native_app_permissions
-- title: Installed Native Apps with network access, integrations or account privileges
-- domain: governance_access   tier: standard
-- entity: native apps = app_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_SPECIFICATIONS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That a grant to an app lists the app name in GRANTEE_NAME
--   is taken from the column description. An app with no specification, no grant and no usage is not listed.
-- read_this: one row = one installed Native App (name and id). approved_external_access and approved_security_integrations
--   count its approved specifications (the access it asked for and you approved); pending_requests are
--   waiting for approval. account_privileges are the privileges granted to it on the account. imported_snowflake
--   is USAGE (how IMPORTED PRIVILEGES is recorded) on the SNOWFLAKE database; snowflake_db_roles counts SNOWFLAKE
--   database roles granted to it. active_days are days with app credits in the window.
-- healthy: status = OK when the app has no external access, no security integration, no account-level
--   privilege and no SNOWFLAKE database access.
-- investigate_if: WARN when the app has approved external access or a security integration, or holds an
--   account-level privilege or SNOWFLAKE database access, or has approved external access and no app credits
--   in the window; CRITICAL when it has approved external access together with SNOWFLAKE database access
--   (grant or database role) or MANAGE GRANTS.
-- actions: 1) revoke or decline external access an app does not need, and drop apps nobody uses (free);
--   2) REVOKE IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE and account privileges from the app (config);
--   3) review pending requests before approving them (free).
-- next: sf_cost_native_app_spend
-- caveats: Endpoint hosts and definitions are never read, only how many specifications are approved. Snowflake
--   records a grant of IMPORTED PRIVILEGES on a shared database as USAGE, so any USAGE on the SNOWFLAKE database
--   counts. No app credits is not no usage: many apps run on your warehouses. APPLICATION_DAILY_USAGE_HISTORY
--   lists apps with credits only and lags a day. Grants are matched to an app by name (the view has no app id),
--   so two installs under one name share them. Specifications of a dropped app may not be marked deleted.
--   GRANTS_TO_ROLES lags up to 2 hours.
WITH sp AS (
  SELECT UPPER(application_name) || '|' || TO_VARCHAR(application_id) AS app_key, UPPER(application_name) AS name_key,
         MAX(application_name) AS app_name, TO_VARCHAR(application_id) AS app_id,
         COUNT_IF(type = 'EXTERNAL_ACCESS' AND status = 'APPROVED') AS approved_external_access,
         COUNT_IF(type = 'SECURITY_INTEGRATION' AND status = 'APPROVED') AS approved_security_integrations,
         COUNT_IF(status = 'PENDING') AS pending_requests
  FROM SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_SPECIFICATIONS
  WHERE deleted IS NULL
  GROUP BY UPPER(application_name), application_id
),
gp AS (
  SELECT DISTINCT UPPER(grantee_name) AS app_key, grantee_name AS app_name, privilege, granted_on, name
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE granted_to = 'APPLICATION' AND deleted_on IS NULL
),
gr AS (
  SELECT app_key AS name_key, MAX(app_name) AS app_name,
         LISTAGG(IFF(granted_on = 'ACCOUNT', privilege, NULL), ', ') WITHIN GROUP (ORDER BY privilege) AS account_privileges,
         COUNT_IF(granted_on = 'ACCOUNT') AS account_privilege_count,
         COUNT_IF(granted_on = 'ACCOUNT' AND privilege = 'MANAGE GRANTS') > 0 AS has_manage_grants,
         COUNT_IF(granted_on = 'DATABASE' AND UPPER(name) = 'SNOWFLAKE' AND privilege IN ('USAGE', 'IMPORTED PRIVILEGES')) > 0
           AS imported_snowflake,
         COUNT_IF(granted_on = 'DATABASE_ROLE' AND UPPER(name) LIKE 'SNOWFLAKE.%') AS snowflake_db_roles
  FROM gp
  GROUP BY 1
),
us AS (
  SELECT UPPER(application_name) || '|' || TO_VARCHAR(application_id) AS app_key, UPPER(application_name) AS name_key,
         MAX(application_name) AS app_name, TO_VARCHAR(application_id) AS app_id,
         COUNT(DISTINCT IFF(credits_used > 0, usage_date, NULL)) AS active_days
  FROM SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY UPPER(application_name), application_id
),
k AS (
  SELECT app_key, name_key FROM sp UNION SELECT app_key, name_key FROM us
  UNION SELECT name_key || '|' AS app_key, name_key FROM gr
  WHERE name_key NOT IN (SELECT name_key FROM sp UNION SELECT name_key FROM us)
),
s AS (
  SELECT k.app_key, COALESCE(sp.app_name, gr.app_name, us.app_name) AS app_name, COALESCE(sp.app_id, us.app_id) AS app_id,
         COALESCE(sp.approved_external_access, 0) AS approved_external_access,
         COALESCE(sp.approved_security_integrations, 0) AS approved_security_integrations,
         COALESCE(sp.pending_requests, 0) AS pending_requests,
         gr.account_privileges, COALESCE(gr.account_privilege_count, 0) AS account_privilege_count,
         COALESCE(gr.has_manage_grants, FALSE) AS has_manage_grants, COALESCE(gr.imported_snowflake, FALSE) AS imported_snowflake,
         COALESCE(gr.snowflake_db_roles, 0) AS snowflake_db_roles,
         COALESCE(us.active_days, 0) AS active_days
  FROM k
  LEFT JOIN sp ON sp.app_key = k.app_key
  LEFT JOIN gr ON gr.name_key = k.name_key
  LEFT JOIN us ON us.app_key = k.app_key
),
f AS (
  SELECT s.*,
         approved_external_access > 0 AND (imported_snowflake OR snowflake_db_roles > 0 OR has_manage_grants) AS powerful_and_open,
         approved_external_access > 0 AND active_days = 0 AS no_app_credits
  FROM s
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, app_name, app_id, approved_external_access,
       approved_security_integrations, pending_requests, account_privileges, account_privilege_count,
       imported_snowflake, snowflake_db_roles, has_manage_grants, active_days,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(approved_external_access > 0, approved_external_access || ' approved external access specifications', NULL),
         IFF(approved_security_integrations > 0, approved_security_integrations || ' approved security integrations', NULL),
         IFF(account_privilege_count > 0, 'account privileges: ' || account_privileges, NULL),
         IFF(imported_snowflake, 'USAGE (IMPORTED PRIVILEGES) on SNOWFLAKE', NULL),
         IFF(snowflake_db_roles > 0, snowflake_db_roles || ' SNOWFLAKE database roles', NULL),
         IFF(no_app_credits, 'can call out but billed no app credits in ' || :period_days || ' days', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN powerful_and_open THEN 'CRITICAL'
         WHEN approved_external_access > 0 OR approved_security_integrations > 0 OR account_privilege_count > 0
           OR imported_snowflake OR snowflake_db_roles > 0 OR no_app_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, approved_external_access DESC, app_name
