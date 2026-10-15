-- query_id: sf_ai_spcs_public_endpoints
-- shims: ROLES, GRANTS_TO_ROLES, GRANTS_TO_USERS, SERVICES
-- reads: INFORMATION_SCHEMA table functions SHOW ROLES, SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role), SHOW GRANTS OF ROLE (per role), SHOW SERVICES
-- fallback_note: account roles only (no database or instance roles); the name stands in for the role id; current grants to account and database roles; no inherited or future grants; current role grants to users; live services only; the name stands in for ids
WITH -- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
-- every role a user can use through a direct grant. A child role is NAME, its parent GRANTEE_NAME.
sf_sec_role_reach AS (
  SELECT name AS top_role, name AS role_name, 0 AS depth, CAST(name AS VARCHAR) AS path
  FROM __SHIM_ROLES__
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT r.top_role, g.name, r.depth + 1, r.path || ' > ' || g.name
  FROM sf_sec_role_reach r
  JOIN __SHIM_GRANTS_TO_ROLES__ g
    ON g.grantee_name = r.role_name AND g.granted_on = 'ROLE' AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
   AND g.privilege = 'USAGE' AND g.deleted_on IS NULL
  -- Snowflake forbids cycles; the cap only guards against a malformed history.
  WHERE r.depth < 20
),
sf_sec_user_roles AS (
  SELECT gu.grantee_name AS user_name, gu.role AS granted_role, r.role_name, r.depth, r.path
  FROM __SHIM_GRANTS_TO_USERS__ gu
  JOIN sf_sec_role_reach r ON r.top_role = gu.role
  WHERE gu.deleted_on IS NULL
),
b AS (
  SELECT grantee_name, granted_to, created_on, deleted_on
  FROM __SHIM_GRANTS_TO_ROLES__
  WHERE granted_on = 'ACCOUNT' AND privilege = 'BIND SERVICE ENDPOINT'
),
bacct AS (
  SELECT COUNT(*) AS grant_rows,
         COUNT_IF(grantee_name = 'PUBLIC' AND deleted_on IS NULL) > 0 AS public_holds,
         MAX(IFF(grantee_name = 'PUBLIC' AND deleted_on IS NULL, created_on, NULL)) AS public_granted_on,
         MAX(IFF(grantee_name = 'PUBLIC', deleted_on, NULL)) AS public_revoked_on,
         COUNT(DISTINCT IFF(grantee_name <> 'PUBLIC' AND deleted_on IS NULL, grantee_name, NULL)) AS other_roles
  FROM b
),
-- a role can bind when it, or a role it inherits, holds the privilege (ACCOUNTADMIN holds it by default)
binders AS (
  SELECT DISTINCT r.top_role AS role_name
  FROM sf_sec_role_reach r
  JOIN b ON b.grantee_name = r.role_name AND b.deleted_on IS NULL AND b.granted_to IN ('ROLE', 'ACCOUNT ROLE')
  UNION
  SELECT 'ACCOUNTADMIN'
),
svc AS (
  SELECT service_id, service_catalog || '.' || service_schema || '.' || service_name AS service_full_name,
         service_name, service_owner, service_owner_role_type, compute_pool_id, compute_pool_name, auto_resume,
         created, last_resumed, last_suspended
  FROM __SHIM_SERVICES__
  WHERE deleted IS NULL AND NOT COALESCE(is_job, FALSE)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY service_id ORDER BY last_altered DESC NULLS LAST) = 1
),
s AS (
  SELECT svc.*,
         last_suspended IS NULL OR last_resumed > last_suspended AS is_running,
         (last_suspended IS NULL OR last_resumed > last_suspended) OR COALESCE(auto_resume, FALSE) AS reachable,
         CASE WHEN COALESCE(service_owner_role_type, 'ROLE') NOT IN ('ROLE', 'ACCOUNT ROLE') THEN NULL
              WHEN service_owner IN (SELECT role_name FROM binders) THEN TRUE
              WHEN (SELECT public_holds FROM bacct) THEN TRUE
              WHEN (SELECT grant_rows FROM bacct) = 0 THEN NULL
              ELSE FALSE END AS owner_can_bind,
         CASE WHEN COALESCE(service_owner_role_type, 'ROLE') NOT IN ('ROLE', 'ACCOUNT ROLE') THEN NULL
              WHEN service_owner = 'ACCOUNTADMIN' THEN 'ACCOUNTADMIN'
              WHEN service_owner IN (SELECT role_name FROM binders) THEN 'owner role'
              WHEN (SELECT public_holds FROM bacct) THEN 'PUBLIC' END AS bind_via
  FROM svc
),
acct AS (
  SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, 'account' AS row_kind,
         '(account) BIND SERVICE ENDPOINT on PUBLIC' AS service_full_name, CAST(NULL AS NUMBER) AS service_id,
         CAST(NULL AS VARCHAR) AS service_owner, CAST(NULL AS VARCHAR) AS compute_pool_name,
         CAST(NULL AS BOOLEAN) AS is_running, CAST(NULL AS BOOLEAN) AS reachable,
         IFF(grant_rows = 0, NULL, public_holds) AS owner_can_bind, IFF(public_holds, 'PUBLIC', NULL) AS bind_via,
         public_granted_on, public_revoked_on, other_roles,
         CASE WHEN grant_rows = 0 THEN 'privilege_not_listed' END AS not_assessed_reason,
         CASE WHEN grant_rows = 0 THEN 'NOT_ASSESSED' WHEN public_holds THEN 'WARN' ELSE 'OK' END AS status
  FROM bacct
),
rows_ AS (
  SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, 'service' AS row_kind,
         service_full_name || ' (' || service_id || ')' AS service_full_name, service_id, service_owner,
         compute_pool_name || ' (' || compute_pool_id || ')' AS compute_pool_name, is_running, reachable,
         owner_can_bind, bind_via, CAST(NULL AS TIMESTAMP_LTZ) AS public_granted_on,
         CAST(NULL AS TIMESTAMP_LTZ) AS public_revoked_on, CAST(NULL AS NUMBER) AS other_roles,
         CASE WHEN owner_can_bind IS NULL AND COALESCE(service_owner_role_type, 'ROLE') NOT IN ('ROLE', 'ACCOUNT ROLE')
                THEN 'owner_not_resolved'
              WHEN owner_can_bind IS NULL THEN 'privilege_not_listed' END AS not_assessed_reason,
         CASE WHEN owner_can_bind IS NULL THEN 'NOT_ASSESSED'
              WHEN owner_can_bind AND reachable THEN 'WARN'
              ELSE 'OK' END AS status
  FROM s
)
SELECT * FROM (
  SELECT * FROM acct
  UNION ALL
  SELECT * FROM rows_
)
ORDER BY CASE row_kind WHEN 'account' THEN 0 ELSE 1 END,
         CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END, service_full_name
