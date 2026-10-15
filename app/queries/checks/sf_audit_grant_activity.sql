-- query_id: sf_audit_grant_activity
-- title: Privileges granted and revoked, and by which role
-- domain: governance_access   tier: standard
-- entity: change groups = granted_by, change_kind, granted_on, privilege, grantee_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one role that granted or revoked (change_kind) a privilege on a kind of object
--   (granted_on) to one grantee in the window. grants counts the changes and objects the distinct objects.
--   OWNERSHIP, account-level privileges and grants of the admin roles are left out: they are
--   sf_sec_privileged_grant_changes. What is left is the everyday flow of access, so a row shows who is
--   handing out access and to whom.
-- healthy: status = OK for grants to named roles and for every revoke.
-- investigate_if: WARN when a privilege was granted to PUBLIC (every user gets it) or WITH GRANT OPTION
--   (the grantee can pass it on); CRITICAL when PUBLIC was granted a write privilege (INSERT, UPDATE,
--   DELETE, TRUNCATE, ALL).
-- actions: 1) revoke the grant to PUBLIC and grant it to the role that needs it (free); 2) do access
--   grants from SECURITYADMIN or a managed-access schema, so owners cannot hand out access on their own
--   (config); 3) manage grants as code so every change has a review (spend).
-- next: sf_gov_public_role_grants
-- empty_if: role_cannot_see, no_activity
-- caveats: GRANTS_TO_ROLES holds a grant from creation to revoke, so a grant made and revoked inside the
--   window shows once as a grant and once as a revoke; a grant made through a future or ALL grant
--   reads as one row. It lags up to 2 hours and shows only what the role can see. Grants to users are
--   role grants and sit in sf_sec_privileged_grant_changes and sf_secx_direct_user_grants.
WITH g AS (
  SELECT 'GRANT' AS change_kind, created_on AS changed_at, privilege, granted_on, name AS object_name,
         grantee_name, granted_by, grant_option
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE created_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND created_on < __AS_OF_DATE__
  UNION ALL
  SELECT 'REVOKE', deleted_on, privilege, granted_on, name, grantee_name, granted_by, grant_option
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND deleted_on < __AS_OF_DATE__
),
f AS (
  SELECT * FROM g
  WHERE privilege <> 'OWNERSHIP' AND granted_on <> 'ACCOUNT'
    AND NOT (granted_on = 'ROLE' AND object_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'USERADMIN', 'ORGADMIN'))
),
a AS (
  SELECT COALESCE(granted_by, '(unknown role)') AS granted_by, change_kind, granted_on, privilege, grantee_name,
         COUNT(*) AS grants, COUNT(DISTINCT object_name) AS objects,
         COUNT_IF(grant_option) AS with_grant_option,
         MIN(changed_at) AS first_change, MAX(changed_at) AS last_change
  FROM f
  GROUP BY 1, 2, 3, 4, 5
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, granted_by, change_kind, granted_on, privilege,
       grantee_name, grants, objects, with_grant_option, first_change, last_change,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(grantee_name = 'PUBLIC' AND change_kind = 'GRANT', 'granted to PUBLIC', NULL),
         IFF(with_grant_option > 0 AND change_kind = 'GRANT', 'with grant option', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN change_kind = 'REVOKE' THEN 'OK'
         WHEN grantee_name = 'PUBLIC' AND privilege IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'ALL', 'ALL PRIVILEGES')
           THEN 'CRITICAL'
         WHEN grantee_name = 'PUBLIC' OR with_grant_option > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM a
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, grants DESC
