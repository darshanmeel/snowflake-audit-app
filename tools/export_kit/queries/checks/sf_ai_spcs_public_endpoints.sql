-- query_id: sf_ai_spcs_public_endpoints
-- title: Container services that can take internet traffic (owner holds BIND SERVICE ENDPOINT)
-- domain: serving_ai   tier: standard
-- entity: container services = service_id
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SERVICES, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- not_assessed_reasons: privilege_not_listed: GRANTS_TO_ROLES has no BIND SERVICE ENDPOINT grant, so
--   whether PUBLIC holds it is not known; owner_not_resolved: the service is owned by a database role or
--   an application, whose grants this check does not follow
-- read_this: one row = the account (does PUBLIC hold BIND SERVICE ENDPOINT?) or one live Snowpark
--   Container Services service that is not a job. A public endpoint is only allowed when the service's
--   owner role holds BIND SERVICE ENDPOINT on the account; Snowflake began granting it to PUBLIC on 18 May
--   2026, which lets every service owner open one. owner_can_bind says whether the owner role holds it
--   directly, through a role it inherits, through PUBLIC, or as ACCOUNTADMIN. reachable is TRUE when the
--   service runs now or resumes on an incoming request (AUTO_RESUME). Whether an endpoint is actually
--   public is only in SHOW ENDPOINTS IN SERVICE, one service at a time.
-- healthy: status = OK when PUBLIC does not hold BIND SERVICE ENDPOINT and no reachable service's owner
--   holds it, or every such service is meant to serve users outside Snowflake.
-- investigate_if: WARN when PUBLIC holds BIND SERVICE ENDPOINT, or a reachable service's owner can bind
--   public endpoints.
-- actions: 1) run SHOW ENDPOINTS IN SERVICE <name> on the flagged services and check is_public and the
--   ingress_url (free); 2) REVOKE BIND SERVICE ENDPOINT ON ACCOUNT FROM ROLE PUBLIC and grant it to the
--   one role that owns internet-facing services (free); 3) suspend or drop services left over from a demo
--   (free)
-- next: sf_ai_snowpark_container_services, sf_ai_spcs_pool_no_live_service
-- caveats: this finds services that can have public endpoints, not the endpoints themselves: no account
--   view lists endpoints. Public ingress still needs a Snowflake login (OAuth), so a public endpoint is not
--   anonymous. Role reach follows live role-to-role grants. SERVICES and GRANTS_TO_ROLES lag up to 2-3
--   hours.
WITH -- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
-- every role a user can use through a direct grant. A child role is NAME, its parent GRANTEE_NAME.
sf_sec_role_reach AS (
  SELECT name AS top_role, name AS role_name, 0 AS depth, CAST(name AS VARCHAR) AS path
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT r.top_role, g.name, r.depth + 1, r.path || ' > ' || g.name
  FROM sf_sec_role_reach r
  JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
    ON g.grantee_name = r.role_name AND g.granted_on = 'ROLE' AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
   AND g.privilege = 'USAGE' AND g.deleted_on IS NULL
  -- Snowflake forbids cycles; the cap only guards against a malformed history.
  WHERE r.depth < 20
),
sf_sec_user_roles AS (
  SELECT gu.grantee_name AS user_name, gu.role AS granted_role, r.role_name, r.depth, r.path
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu
  JOIN sf_sec_role_reach r ON r.top_role = gu.role
  WHERE gu.deleted_on IS NULL
),
b AS (
  SELECT grantee_name, granted_to, created_on, deleted_on
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVICES
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
