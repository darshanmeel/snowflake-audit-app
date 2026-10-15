-- query_id: sf_gov_integrations_exposure
-- shims: GRANTS_TO_ROLES
-- reads: INFORMATION_SCHEMA table functions SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role)
-- fallback_note: current grants to account and database roles; no inherited or future grants
-- pre: SHOW INTEGRATIONS
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
  FROM __SHIM_GRANTS_TO_ROLES__
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
