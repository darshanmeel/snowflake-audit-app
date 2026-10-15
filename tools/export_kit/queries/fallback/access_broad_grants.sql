-- query_id: access_broad_grants
-- shims: USERS, GRANTS_TO_USERS, GRANTS_TO_ROLES
-- reads: INFORMATION_SCHEMA table functions SHOW USERS, SHOW GRANTS OF ROLE (per role), SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role)
-- fallback_note: live users only; no password-change dates; the name stands in for the user id; current role grants to users; current grants to account and database roles; no inherited or future grants
WITH active_user_names AS (
  SELECT name
  FROM __SHIM_USERS__
  WHERE deleted_on IS NULL AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)
),
active_users AS (
  SELECT COUNT(*) AS n FROM active_user_names
),
role_holders AS (
  SELECT role, COUNT(DISTINCT grantee_name) AS holders
  FROM __SHIM_GRANTS_TO_USERS__
  WHERE deleted_on IS NULL
  GROUP BY role
),
wide_roles AS (
  -- field heuristic for "granted to many users"
  SELECT r.role, r.holders
  FROM role_holders r CROSS JOIN active_users u
  WHERE r.holders >= GREATEST(10, 0.25 * u.n)
),
grants AS (
  SELECT g.granted_on AS securable_type,
         COALESCE(g.table_catalog || '.', '') || COALESCE(g.table_schema || '.', '') || g.name AS securable,
         g.granted_on, g.name, g.grantee_name, g.privilege, w.holders,
         g.grantee_name = 'PUBLIC' AS is_all_users,
         (g.privilege IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'OWNERSHIP', 'MODIFY', 'EVOLVE SCHEMA', 'REBUILD')
           OR g.privilege LIKE 'CREATE %' OR g.privilege LIKE 'APPLY%') AS is_write,
         g.privilege IN ('OWNERSHIP', 'MANAGE GRANTS') AS is_manage,
         g.granted_on = 'ROLE' AND g.name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'USERADMIN', 'ORGADMIN') AS is_admin_role
  FROM __SHIM_GRANTS_TO_ROLES__ g
  LEFT JOIN wide_roles w ON w.role = g.grantee_name
  WHERE g.deleted_on IS NULL
    AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
    -- grants to PUBLIC have one home, sf_gov_public_role_grants, so the two never count a grant twice
    AND g.grantee_name <> 'PUBLIC' AND w.role IS NOT NULL
),
flagged AS (
  SELECT g.*,
         CASE
           WHEN is_admin_role THEN 'admin role ' || name || ' granted to ' || IFF(is_all_users, 'every user', 'a role held by ' || holders || ' users')
           WHEN is_all_users AND (is_write OR is_manage) THEN 'write privilege granted to every user in the account'
           WHEN is_all_users THEN 'granted to every user in the account'
           WHEN is_manage THEN privilege || ' granted to a role held by ' || holders || ' users'
           WHEN is_write THEN 'write privilege granted to a role held by ' || holders || ' users'
         END AS reason,
         CASE
           WHEN is_admin_role THEN 'CRITICAL'
           WHEN is_all_users AND (is_write OR is_manage) THEN 'CRITICAL'
           WHEN is_all_users OR is_manage OR is_write THEN 'WARN'
         END AS status
  FROM grants g
),
-- Distinct active people who directly hold any role with a flagged grant: one figure for the whole check.
reach AS (
  SELECT COUNT(DISTINCT gu.grantee_name) AS users_holding_broad
  FROM __SHIM_GRANTS_TO_USERS__ gu
  JOIN active_user_names a ON a.name = gu.grantee_name
  WHERE gu.deleted_on IS NULL
    AND gu.role IN (SELECT grantee_name FROM flagged WHERE status IS NOT NULL)
)
SELECT 0 AS window_days, securable_type, securable,
       IFF(is_all_users, 'ALL_USERS', 'ROLE') AS grantee_type, grantee_name AS grantee,
       privilege AS privilege_type, FALSE AS is_inherited, CAST(NULL AS VARCHAR) AS inherited_from,
       holders, r.users_holding_broad, u.n AS active_users,
       reason, status
FROM flagged
CROSS JOIN reach r
CROSS JOIN active_users u
WHERE status IS NOT NULL
QUALIFY ROW_NUMBER() OVER (ORDER BY IFF(status = 'CRITICAL', 0, 1), securable_type, securable, privilege, grantee_name) <= :top_n
ORDER BY IFF(status = 'CRITICAL', 0, 1), securable_type, securable, privilege_type, grantee
