-- query_id: sf_gov_integrations_exposure
-- title: Integrations that open paths in or out of the account
-- domain: governance_access   tier: standard
-- entity: integrations = integration_name
-- windowed: no
-- pre: SHOW INTEGRATIONS
-- reads: SHOW INTEGRATIONS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those)
-- params: :warn_usage_roles (default 5) usage roles: at or above this the row reads WARN; :recent_days
--   (default 30) recent days: value this check uses
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one integration (security, storage, external access, API, notification,
--   catalog). usage_roles lists roles with USAGE or OWNERSHIP on it; public_usage is TRUE when PUBLIC
--   has it (every user). egress_path is TRUE for categories that let code or stages reach outside
--   Snowflake (EXTERNAL_ACCESS, API, STORAGE).
-- healthy: status = OK when the integration is used by a few named roles, or it is disabled.
-- investigate_if: WARN when an enabled egress integration is usable by :warn_usage_roles+ roles, was
--   created in the last :recent_days days, or a security (SSO / OAuth / SCIM) integration was created
--   recently; CRITICAL when PUBLIC can use an enabled integration.
-- actions: 1) REVOKE USAGE from PUBLIC and broad roles; grant it to the one role that runs the pipeline
--   (free); 2) drop disabled or unused integrations (free); 3) restrict external access integrations to
--   network rules with only the hosts needed (config)
-- next: none
-- caveats: SHOW INTEGRATIONS lists what the audit role can see; allowed locations, hosts and OAuth
--   settings need DESCRIBE INTEGRATION and are not read here. Grants lag up to 2 hours.
WITH i AS (
  SELECT x."name" AS integration_name, UPPER(x."type") AS integration_type, UPPER(x."category") AS category,
         LOWER(TO_VARCHAR(x."enabled")) = 'true' AS is_enabled, x."comment" AS integration_comment,
         x."created_on" AS created_on
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) x
),
u AS (
  SELECT name AS integration_name,
         LISTAGG(DISTINCT grantee_name, ', ') WITHIN GROUP (ORDER BY grantee_name) AS usage_roles,
         COUNT(DISTINCT grantee_name) AS usage_role_count,
         BOOLOR_AGG(grantee_name = 'PUBLIC') AS public_usage,
         MAX(IFF(privilege = 'OWNERSHIP', grantee_name, NULL)) AS owner_role
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE granted_on = 'INTEGRATION' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
    AND privilege IN ('USAGE', 'OWNERSHIP')
  GROUP BY name
),
j AS (
  -- An integration that has grants but is not in SHOW is one the role cannot see: listed, not dropped.
  SELECT COALESCE(i.integration_name, u.integration_name) AS integration_name, i.integration_type, i.category,
         i.is_enabled, i.integration_comment, i.created_on, i.integration_name IS NULL AS not_visible, u.owner_role, u.usage_roles, COALESCE(u.usage_role_count, 0) AS usage_role_count,
         COALESCE(u.public_usage, FALSE) AS public_usage,
         (i.category IN ('EXTERNAL_ACCESS', 'API', 'STORAGE') OR i.integration_type LIKE '%EXTERNAL_ACCESS%') AS egress_path,
         DATEDIFF(day, i.created_on, __AS_OF_DATE__) AS age_days
  FROM i FULL OUTER JOIN u ON u.integration_name = i.integration_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, integration_name, integration_type, category, is_enabled,
       egress_path, owner_role, usage_roles, usage_role_count, public_usage, created_on, age_days,
       integration_comment,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NOT is_enabled, 'disabled', NULL),
         IFF(not_visible, 'in grants but not in SHOW INTEGRATIONS (the role cannot see it)', NULL),
         IFF(public_usage, 'PUBLIC can use it', NULL),
         IFF(egress_path AND usage_role_count >= :warn_usage_roles, usage_role_count || ' roles can use it', NULL),
         IFF(age_days < :recent_days, 'created ' || age_days || ' days ago', NULL),
         IFF(egress_path, 'path out of the account (' || category || ')', NULL)), '; ') AS reasons,
       IFF(not_visible AND NOT public_usage, 'integration_not_visible', NULL) AS not_assessed_reason,
       CASE
         WHEN public_usage AND COALESCE(is_enabled, TRUE) THEN 'CRITICAL'
         WHEN not_visible THEN 'NOT_ASSESSED'
         WHEN NOT is_enabled THEN 'OK'
         WHEN egress_path AND (usage_role_count >= :warn_usage_roles OR age_days < :recent_days) THEN 'WARN'
         WHEN category = 'SECURITY' AND age_days < :recent_days THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, category, integration_name
