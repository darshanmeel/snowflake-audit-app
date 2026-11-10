-- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
-- every role a user can use through a direct grant. A child role is NAME, its parent GRANTEE_NAME.
sf_sec_role_reach AS (
  SELECT name AS top_role, name AS role_name, 0 AS depth, CAST(name AS VARCHAR) AS path
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL
  UNION ALL
  -- A database role is named DATABASE.ROLE, as in the Access Explorer, so it never clashes with an account role.
  SELECT r.top_role, g.child, r.depth + 1, r.path || ' > ' || g.child
  FROM sf_sec_role_reach r
  JOIN (SELECT IFF(granted_on = 'DATABASE_ROLE' AND NOT CONTAINS(name, '.'), table_catalog || '.' || name, name) AS child,
               IFF(granted_to = 'DATABASE_ROLE' AND NOT CONTAINS(grantee_name, '.'),
                   table_catalog || '.' || grantee_name, grantee_name) AS parent
        FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
        WHERE granted_on IN ('ROLE', 'DATABASE_ROLE') AND granted_to IN ('ROLE', 'ACCOUNT ROLE', 'DATABASE_ROLE')
          AND privilege = 'USAGE' AND deleted_on IS NULL) g
    ON g.parent = r.role_name
  -- Snowflake forbids cycles; the cap only guards against a malformed history.
  WHERE r.depth < 20
),
sf_sec_user_roles AS (
  SELECT gu.grantee_name AS user_name, gu.role AS granted_role, r.role_name, r.depth, r.path
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu
  JOIN sf_sec_role_reach r ON r.top_role = gu.role
  WHERE gu.deleted_on IS NULL
)
