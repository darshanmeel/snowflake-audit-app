-- query_id: sf_acc_disabled_users_roles
-- title: Disabled users that still hold roles
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one disabled user that has not been dropped. direct_roles counts roles granted to
--   the user; admin_roles lists the admin roles the user could use again.
-- healthy: status = OK when the user holds no roles.
-- investigate_if: WARN when the user still holds roles: enabling the user again brings all access back
--   at once; CRITICAL when one of them leads to an admin role.
-- actions: 1) revoke the roles, or drop the user when the person has left (free)
-- next: none
-- caveats: every user also holds PUBLIC, which is not counted. Lags up to 2 hours.
WITH __INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
held AS (
  SELECT user_name, COUNT(DISTINCT granted_role) AS direct_roles,
         LISTAGG(DISTINCT granted_role, ', ') WITHIN GROUP (ORDER BY granted_role) AS role_list,
         COUNT(DISTINCT role_name) AS reachable_roles,
         LISTAGG(DISTINCT IFF(role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN', 'SYSADMIN'),
                              role_name, NULL), ', ') AS admin_roles
  FROM sf_sec_user_roles
  GROUP BY user_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, u.user_id, u.user_name, u.user_type, u.default_role,
       u.last_success_login, COALESCE(h.direct_roles, 0) AS direct_roles, h.role_list,
       COALESCE(h.reachable_roles, 0) AS reachable_roles, NULLIF(h.admin_roles, '') AS admin_roles,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(COALESCE(h.direct_roles, 0) > 0, 'disabled but holds ' || h.role_list, NULL),
         IFF(NULLIF(h.admin_roles, '') IS NOT NULL, 'could use ' || h.admin_roles || ' again', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN NULLIF(h.admin_roles, '') IS NOT NULL THEN 'CRITICAL'
         WHEN COALESCE(h.direct_roles, 0) > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM sf_sec_users u
LEFT JOIN held h ON h.user_name = u.user_name
WHERE u.is_disabled
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, direct_roles DESC, u.user_name
