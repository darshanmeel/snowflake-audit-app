-- query_id: sf_sec_privileged_grant_changes
-- title: Admin roles, account privileges and ownership granted or revoked
-- domain: governance_access   tier: standard
-- entity: grantees = grantee_type, grantee
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one privileged grant created or revoked in the window: an admin role
--   (ACCOUNTADMIN, SECURITYADMIN, ORGADMIN, USERADMIN, SYSADMIN) granted to a user or a role, an
--   account-level privilege (e.g. MANAGE GRANTS, CREATE USER, APPLY MASKING POLICY), or OWNERSHIP of a
--   database, schema, integration, role, user or warehouse. grantee is the user or role that received
--   it (grantee_type says which). granted_by is the role that made the grant.
-- healthy: status = OK for revocations and for ordinary ownership transfers done by an admin role.
-- investigate_if: WARN for OWNERSHIP transfers of roles, users and integrations, and grants of
--   USERADMIN / SYSADMIN or account privileges; CRITICAL when ACCOUNTADMIN, SECURITYADMIN, ORGADMIN or
--   MANAGE GRANTS was granted to anyone.
-- actions: 1) match each CRITICAL grant to an approved change; revoke if none (free); 2) route admin
--   grants through a ticketed break-glass process and alert on them (config)
-- next: none
-- caveats: the executing person is not stored on the grant (only the granting role); use
--   sf_sec_security_config_changes or QUERY_HISTORY for who ran it. A grant that was created and
--   revoked inside the window shows twice. Lags up to 2 hours.
WITH ev AS (
  SELECT created_on AS change_time, 'GRANTED' AS change_type, 'USER' AS grantee_type, grantee_name,
         'USAGE' AS privilege, 'ROLE' AS object_type, role AS object_name, granted_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
  WHERE created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND created_on < __AS_OF_DATE__
  UNION ALL
  SELECT deleted_on, 'REVOKED', 'USER', grantee_name, 'USAGE', 'ROLE', role, granted_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
  WHERE deleted_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND deleted_on < __AS_OF_DATE__
  UNION ALL
  SELECT created_on, 'GRANTED', granted_to, grantee_name, privilege, granted_on,
         COALESCE(table_catalog || '.', '') || COALESCE(table_schema || '.', '') || name, granted_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND created_on < __AS_OF_DATE__
  UNION ALL
  SELECT deleted_on, 'REVOKED', granted_to, grantee_name, privilege, granted_on,
         COALESCE(table_catalog || '.', '') || COALESCE(table_schema || '.', '') || name, granted_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND deleted_on < __AS_OF_DATE__
),
k AS (
  SELECT ev.*,
         CASE
           WHEN object_type = 'ROLE' AND privilege = 'USAGE'
                AND object_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN') THEN 'top_admin_role'
           WHEN object_type = 'ACCOUNT' AND privilege IN ('MANAGE GRANTS', 'MANAGE ACCOUNT SUPPORT CASES') THEN 'manage_grants'
           WHEN object_type = 'ROLE' AND privilege = 'USAGE' AND object_name IN ('USERADMIN', 'SYSADMIN') THEN 'admin_role'
           WHEN object_type = 'ACCOUNT' THEN 'account_privilege'
           WHEN privilege = 'OWNERSHIP' AND object_type IN ('ROLE', 'USER', 'INTEGRATION') THEN 'sensitive_ownership'
           WHEN privilege = 'OWNERSHIP' AND object_type IN ('DATABASE', 'SCHEMA', 'WAREHOUSE') THEN 'ownership'
         END AS change_kind
  FROM ev
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, change_time, change_type, change_kind,
       grantee_type,
       IFF(grantee_type = 'USER', grantee_name, NULL) AS user_name,
       IFF(grantee_type = 'USER', NULL, grantee_name) AS grantee_role,
       -- the user or role that received it, so a role grantee is never grouped as "no user"
       grantee_name AS grantee,
       privilege, object_type, object_name, granted_by AS granted_by_role,
       change_type || ' ' || privilege || ' on ' || object_type || ' ' || object_name || ' to '
         || grantee_type || ' ' || grantee_name || ' by ' || COALESCE(granted_by, '?') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN change_type = 'REVOKED' THEN 'OK'
         WHEN change_kind IN ('top_admin_role', 'manage_grants') THEN 'CRITICAL'
         WHEN change_kind IN ('admin_role', 'account_privilege', 'sensitive_ownership') THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM k
WHERE change_kind IS NOT NULL
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, change_time DESC
