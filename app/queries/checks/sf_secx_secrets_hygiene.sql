-- query_id: sf_secx_secrets_hygiene
-- title: Secrets that are old, widely usable or owned by admin roles
-- domain: governance_access   tier: standard
-- entity: secrets = secret_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SECRETS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :max_secret_days (default 180) secret days: limit above which the row flags;
--   :warn_usage_roles (default 3) usage roles: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live secret object (PASSWORD, GENERIC_STRING, OAUTH2, CLOUD_PROVIDER_TOKEN
--   ...), the credentials that functions and procedures use through external access integrations.
--   age_days counts from LAST_ALTERED (the last ALTER SECRET, e.g. a new value), else CREATED.
--   usage_roles lists roles with USAGE or READ on it besides its owner.
-- healthy: status = OK when a static credential was changed in the last :max_secret_days days, one or
--   two pipeline roles can use it, and a functional role owns it.
-- investigate_if: WARN when a PASSWORD or GENERIC_STRING secret has not changed for :max_secret_days+
--   days, :warn_usage_roles+ roles can use it, or ACCOUNTADMIN / SECURITYADMIN / SYSADMIN owns it;
--   CRITICAL when PUBLIC can use or read it.
-- actions: 1) rotate the credential at its source and ALTER SECRET ... SET SECRET_STRING / PASSWORD
--   (free); 2) REVOKE USAGE / READ from PUBLIC and broad roles; grant it to the role that owns the code
--   (free); 3) prefer OAUTH2 or cloud-provider secrets that expire over static keys (config)
-- next: none
-- caveats: LAST_ALTERED also moves for comment changes, so age_days can be too low; which integration
--   or function uses a secret needs DESCRIBE and is not read here. Lags up to 2 hours.
WITH
sec AS (
  SELECT TO_VARCHAR(id) AS secret_id, "DATABASE" AS database_name, "SCHEMA" AS schema_name, name AS secret_name,
         owner AS secret_owner, UPPER(secret_type) AS secret_type,
         created_on AS created, last_altered_on AS last_altered, "COMMENT" AS secret_comment
  FROM SNOWFLAKE.ACCOUNT_USAGE.SECRETS
  WHERE deleted_on IS NULL
),
g AS (
  SELECT table_catalog AS database_name, table_schema AS schema_name, name AS secret_name,
         LISTAGG(DISTINCT IFF(privilege <> 'OWNERSHIP', grantee_name, NULL), ', ') AS usage_roles,
         COUNT(DISTINCT IFF(privilege <> 'OWNERSHIP', grantee_name, NULL)) AS usage_role_count,
         BOOLOR_AGG(grantee_name = 'PUBLIC' AND privilege <> 'OWNERSHIP') AS public_usage
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
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
