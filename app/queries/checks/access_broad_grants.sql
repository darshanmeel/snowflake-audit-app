-- query_id: access_broad_grants
-- title: Broad grants: an admin role, write, ownership or grant management to a role many users
--   hold
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :top_n (default 100000) row cap - far above any account's real grant count, because this is
--   already a findings list (broad grants only) and a cut row would read as "not flagged"
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one (securable, grantee, privilege) grant that is BROAD - this is a filtered
--   findings list, not the full grant rollup (that is access_grants_inventory). The columns that
--   matter are securable (the full database.schema.table name), grantee (a user is masked when
--   masking is on; a role is always shown in full - role names are not personal data),
--   reason (plain words for why this row is here) and status. holders = users who directly hold the
--   grantee role; users_holding_broad = distinct active users who directly hold any role with a row
--   here, of active_users (the same on every row, never added up).
-- healthy: not a row here - a grant to a role few users hold, or a read privilege, is ordinary access
--   and does not appear (PUBLIC grants are in sf_gov_public_role_grants); see access_grants_inventory for the complete, unfiltered rollup
--   every grant (broad or not) belongs to.
-- investigate_if: CRITICAL - an admin role (ACCOUNTADMIN, SECURITYADMIN, SYSADMIN, USERADMIN,
--   ORGADMIN) granted to a role many users hold: read reason and securable first. WARN - a write,
--   OWNERSHIP or MANAGE GRANTS privilege granted to a role many users hold (at any scope).
-- actions: 1) open the securable in Snowflake (SHOW GRANTS ON ...) and confirm who actually needs
--   this access today; revoke or narrow the grant to the smallest scope and privilege that does the
--   job (free); 2) for an OWNERSHIP or MANAGE GRANTS grant to a shared role, confirm the role's real membership is
--   "people who should be able to grant/revoke access here", not a broader role reused from
--   somewhere else (free/config); 3) for a grant to every user in the account, replace it with
--   grants to the specific named roles that need it (config); 4) if the access is genuinely meant
--   to be this broad, record why on the object's own comment or tag so a future audit does not
--   re-flag it for nothing (free).
-- next: none
-- caveats: a "group" = a role held directly by at least 10 users and a quarter of active users. Flags
--   grants to those of write, ownership or grant-management privileges, or an admin role; grants to
--   PUBLIC are in sf_gov_public_role_grants, not here. Only direct grants, so is_inherited is FALSE and
--   inherited_from NULL.
WITH active_user_names AS (
  SELECT name
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)
),
active_users AS (
  SELECT COUNT(*) AS n FROM active_user_names
),
role_holders AS (
  SELECT role, COUNT(DISTINCT grantee_name) AS holders
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
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
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu
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
