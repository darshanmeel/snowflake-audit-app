-- query_id: sf_govx_external_stage_credentials
-- shims: GRANTS_TO_ROLES
-- reads: INFORMATION_SCHEMA table functions SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role)
-- fallback_note: current grants to account and database roles; no inherited or future grants
-- pre: SHOW STAGES IN ACCOUNT
WITH st AS (
  SELECT x."database_name" AS database_name, x."schema_name" AS schema_name, x."name" AS stage_name,
         UPPER(x."type") AS stage_type, x."url" AS url, x."cloud" AS cloud, x."region" AS region,
         x."owner" AS stage_owner, NULLIF(x."storage_integration", '') AS storage_integration,
         UPPER(TO_VARCHAR(x."has_credentials")) IN ('Y', 'TRUE') AS has_credentials,
         x."created_on" AS created_on, x."comment" AS stage_comment
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) x
),
g AS (
  SELECT table_catalog AS database_name, table_schema AS schema_name, name AS stage_name,
         LISTAGG(DISTINCT IFF(privilege <> 'OWNERSHIP', grantee_name, NULL), ', ') AS usage_roles,
         COUNT(DISTINCT IFF(privilege <> 'OWNERSHIP', grantee_name, NULL)) AS usage_role_count,
         BOOLOR_AGG(grantee_name = 'PUBLIC' AND privilege <> 'OWNERSHIP') AS public_usage,
         LISTAGG(DISTINCT IFF(grantee_name = 'PUBLIC', privilege, NULL), ', ') AS public_privileges
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE granted_on = 'STAGE' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
  GROUP BY 1, 2, 3
),
hidden AS (
  -- Stages with grants but no SHOW row: the role cannot see them, so nothing is known about their keys.
  SELECT g.* FROM g LEFT JOIN st ON st.database_name = g.database_name AND st.schema_name = g.schema_name
                                 AND st.stage_name = g.stage_name
  WHERE st.stage_name IS NULL
),
j AS (
  SELECT st.*, st.stage_type LIKE 'EXTERNAL%' AS is_external, NULLIF(g.usage_roles, '') AS usage_roles,
         COALESCE(g.usage_role_count, 0) AS usage_role_count, COALESCE(g.public_usage, FALSE) AS public_usage,
         NULLIF(g.public_privileges, '') AS public_privileges
  FROM st
  LEFT JOIN g ON g.database_name = st.database_name AND g.schema_name = st.schema_name AND g.stage_name = st.stage_name
),
s AS (
  SELECT j.*,
         CASE
           WHEN has_credentials OR public_usage THEN 'CRITICAL'
           WHEN is_external AND (storage_integration IS NULL OR usage_role_count >= :warn_usage_roles) THEN 'WARN'
           ELSE 'OK'
         END AS status
  FROM j
  WHERE is_external OR public_usage
),
out_ AS (
  SELECT database_name, schema_name, stage_name, stage_type, url, cloud, region, stage_owner, storage_integration,
         has_credentials, usage_roles, usage_role_count, public_usage, public_privileges, created_on, stage_comment,
         is_external, status, CAST(NULL AS VARCHAR) AS reason
  FROM s
  UNION ALL
  -- a hidden stage PUBLIC can use is exposed whatever its type
  SELECT database_name, schema_name, stage_name, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN), usage_roles,
         usage_role_count, public_usage, public_privileges, CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS VARCHAR),
         CAST(NULL AS BOOLEAN), 'CRITICAL', CAST(NULL AS VARCHAR)
  FROM hidden WHERE public_usage
  UNION ALL
  -- every other hidden stage is one line, so a blind role is never read as clean
  SELECT CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), '(' || COUNT(*) || ' stages the role cannot see)',
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN), CAST(NULL AS VARCHAR),
         CAST(NULL AS BIGINT), CAST(NULL AS BOOLEAN), CAST(NULL AS VARCHAR), CAST(NULL AS TIMESTAMP_LTZ),
         CAST(NULL AS VARCHAR), CAST(NULL AS BOOLEAN), 'NOT_ASSESSED', 'stages_not_visible'
  FROM hidden WHERE NOT public_usage HAVING COUNT(*) > 0
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name, stage_name,
       IFF(database_name IS NULL, stage_name, database_name || '.' || schema_name || '.' || stage_name) AS stage_fqn,
       stage_type, url, cloud, region,
       stage_owner, storage_integration, has_credentials, usage_roles, usage_role_count, public_usage,
       public_privileges, created_on, stage_comment,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(has_credentials, 'cloud keys stored in the stage', NULL),
         IFF(public_usage, 'PUBLIC has ' || public_privileges, NULL),
         IFF(is_external AND storage_integration IS NULL AND NOT has_credentials, 'no storage integration', NULL),
         IFF(usage_role_count >= :warn_usage_roles, usage_role_count || ' roles can use it', NULL),
         IFF(reason IS NOT NULL, 'listed in grants but not in SHOW STAGES (the role cannot see them)', NULL)), '; ') AS reasons,
       reason AS not_assessed_reason,
       status
FROM out_
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END, stage_fqn
