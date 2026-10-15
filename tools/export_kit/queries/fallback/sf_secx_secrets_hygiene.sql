-- query_id: sf_secx_secrets_hygiene
-- shims: SECRETS, GRANTS_TO_ROLES
-- reads: INFORMATION_SCHEMA table functions SHOW SECRETS, SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role)
-- fallback_note: live secrets only; no token expiry dates; the name stands in for ids; current grants to account and database roles; no inherited or future grants
WITH
sec AS (
  SELECT TO_VARCHAR(id) AS secret_id, "DATABASE" AS database_name, "SCHEMA" AS schema_name, name AS secret_name,
         owner AS secret_owner, UPPER(secret_type) AS secret_type,
         created_on AS created, last_altered_on AS last_altered, "COMMENT" AS secret_comment
  FROM __SHIM_SECRETS__
  WHERE deleted_on IS NULL
),
g AS (
  SELECT table_catalog AS database_name, table_schema AS schema_name, name AS secret_name,
         LISTAGG(DISTINCT IFF(privilege <> 'OWNERSHIP', grantee_name, NULL), ', ') AS usage_roles,
         COUNT(DISTINCT IFF(privilege <> 'OWNERSHIP', grantee_name, NULL)) AS usage_role_count,
         BOOLOR_AGG(grantee_name = 'PUBLIC' AND privilege <> 'OWNERSHIP') AS public_usage
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE granted_on = 'SECRET' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
  GROUP BY 1, 2, 3
),
j AS (
  SELECT s.*, NULLIF(g.usage_roles, '') AS usage_roles, COALESCE(g.usage_role_count, 0) AS usage_role_count,
         COALESCE(g.public_usage, FALSE) AS public_usage,
         DATEDIFF(day, COALESCE(s.last_altered, s.created), __AS_OF_DATE__) AS age_days,
         s.secret_owner IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'ORGADMIN') AS admin_owner
  FROM sec s
  LEFT JOIN g ON g.database_name = s.database_name AND g.schema_name = s.schema_name AND g.secret_name = s.secret_name
),
st AS (
  SELECT j.*,
         (secret_type IN ('PASSWORD', 'GENERIC_STRING') AND age_days >= :max_secret_days) AS stale_static,
         CASE
           WHEN public_usage THEN 'CRITICAL'
           WHEN (secret_type IN ('PASSWORD', 'GENERIC_STRING') AND age_days >= :max_secret_days)
                OR usage_role_count >= :warn_usage_roles OR admin_owner THEN 'WARN'
           ELSE 'OK'
         END AS status
  FROM j
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, secret_id, database_name, schema_name, secret_name,
       database_name || '.' || schema_name || '.' || secret_name AS secret_fqn, secret_type, secret_owner,
       created, last_altered, age_days, usage_roles, usage_role_count, public_usage, secret_comment,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(public_usage, 'PUBLIC can use it', NULL),
         IFF(stale_static, 'static credential unchanged for ' || age_days || ' days', NULL),
         IFF(usage_role_count >= :warn_usage_roles, usage_role_count || ' roles can use it', NULL),
         IFF(admin_owner, 'owned by ' || secret_owner, NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       status
FROM st
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, age_days DESC
