-- query_id: sf_acc_redundant_role_grants
-- title: Role grants a user or role already gets through another role
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ROLES, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one direct role grant (to a user or a role) that the grantee also gets through
--   another of its roles. through_roles lists those roles; example_path shows one way round, from the other role.
-- healthy: status = OK never appears; no rows means no role is granted twice.
-- investigate_if: WARN on every row: the direct grant adds nothing today and keeps the access when the
--   other role is taken away.
-- actions: 1) revoke the direct grant, unless the other path is about to go (free)
-- next: none
-- caveats: paths through the system roles (ACCOUNTADMIN, SECURITYADMIN, USERADMIN, SYSADMIN, ORGADMIN)
--   are left out, since those inherit custom roles by design, and so are grants to the system roles.
--   Lags up to 2 hours.
WITH __INCLUDE_sf_sec_user_roles__,
direct AS (
  SELECT 'USER' AS grantee_type, grantee_name AS grantee, role AS granted_role
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT 'ROLE', grantee_name, name
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on IS NULL AND granted_on = 'ROLE' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND privilege = 'USAGE'
    AND grantee_name NOT IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'SYSADMIN', 'ORGADMIN', 'GLOBALORGADMIN')
),
twice AS (
  SELECT d.grantee_type, d.grantee, d.granted_role,
         LISTAGG(DISTINCT o.granted_role, ', ') WITHIN GROUP (ORDER BY o.granted_role) AS through_roles,
         COUNT(DISTINCT o.granted_role) AS through_count,
         MIN(r.path) AS example_path
  FROM direct d
  JOIN direct o ON o.grantee_type = d.grantee_type AND o.grantee = d.grantee AND o.granted_role <> d.granted_role
  JOIN sf_sec_role_reach r ON r.top_role = o.granted_role AND r.role_name = d.granted_role AND r.depth > 0
  WHERE o.granted_role NOT IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'SYSADMIN', 'ORGADMIN', 'GLOBALORGADMIN')
  GROUP BY 1, 2, 3
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, grantee_type, grantee, granted_role, through_roles,
       through_count, example_path,
       granted_role || ' is granted directly and also through ' || through_roles AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason, 'WARN' AS status
FROM twice
ORDER BY grantee_type DESC, grantee, granted_role
