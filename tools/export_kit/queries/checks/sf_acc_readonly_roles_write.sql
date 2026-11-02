-- query_id: sf_acc_readonly_roles_write
-- title: Read-only roles that can change data
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ROLES, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :read_share (default 0.8) read share: a role that only reads this share of its tables counts as
--   read-only; :min_objects (default 5) objects: the share counts from this many tables up
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one custom role that looks read-only, by its name or by what it holds. The name
--   counts when READ, RO, READER, VIEWER, REPORTING or READONLY is a word in it; what it holds counts
--   when it only reads at least :read_share of its :min_objects+ tables.
--   write_objects counts tables it can change (INSERT, UPDATE, DELETE, TRUNCATE, ownership) or schemas
--   it can create in, held directly or through roles it inherits; example_path shows where one comes from.
-- healthy: status = OK when the role only reads.
-- investigate_if: WARN when it can change data: a reviewer trusts the name or the pattern, and the write
--   access goes unseen.
-- actions: 1) revoke the write grant, or move it to a role whose name says write (free); 2) rename the
--   role if it is meant to write (free)
-- next: none
-- caveats: a guess from names and grants; review before acting. Database roles are not followed. Lags up
--   to 2 hours.
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
roles AS (
  SELECT name AS role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL AND COALESCE(role_type, 'ROLE') = 'ROLE'
    AND name NOT IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'USERADMIN', 'SYSADMIN', 'ORGADMIN', 'PUBLIC', 'GLOBALORGADMIN')
),
g AS (
  SELECT grantee_name AS role_name, granted_on || ':' || COALESCE(table_catalog || '.', '')
           || COALESCE(table_schema || '.', '') || name AS obj, privilege,
         granted_on = 'SCHEMA' AS is_schema
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on IS NULL AND granted_to IN ('ROLE', 'ACCOUNT ROLE')
    AND (granted_on IN ('TABLE', 'VIEW', 'MATERIALIZED_VIEW', 'MATERIALIZED VIEW', 'DYNAMIC_TABLE',
                        'EXTERNAL_TABLE', 'ICEBERG_TABLE', 'EVENT_TABLE')
         OR (granted_on = 'SCHEMA' AND privilege LIKE 'CREATE %'))
),
eff AS (
  SELECT r.top_role AS role_name, g.obj, BOOLOR_AGG(g.is_schema) AS is_schema,
         BOOLOR_AGG(g.privilege IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'OWNERSHIP') OR g.is_schema) AS writes,
         MIN(IFF(g.privilege IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'OWNERSHIP') OR g.is_schema,
                 r.path || ' > ' || g.privilege || ' on ' || g.obj, NULL)) AS write_path
  FROM sf_sec_role_reach r
  JOIN g ON g.role_name = r.role_name
  GROUP BY 1, 2
),
agg AS (
  SELECT role_name, COUNT_IF(NOT is_schema) AS tables_, COUNT_IF(writes) AS write_objects,
         COUNT_IF(NOT is_schema AND NOT writes) AS read_only_tables, MIN(write_path) AS example_path
  FROM eff
  GROUP BY role_name
),
holders AS (
  SELECT role_name, COUNT(DISTINCT user_name) AS users FROM sf_sec_user_roles GROUP BY role_name
),
s AS (
  SELECT r.role_name, COALESCE(a.tables_, 0) AS tables_, COALESCE(a.read_only_tables, 0) AS read_only_tables,
         COALESCE(a.write_objects, 0) AS write_objects, a.example_path, COALESCE(h.users, 0) AS users,
         REGEXP_LIKE(r.role_name, '(^|.*_)(READ|RO|R|READER|READERS|VIEWER|VIEWERS|RPT|REPORTING|READONLY|READ_ONLY)(_.*|$)', 'i')
           AS name_says_read,
         COALESCE(a.tables_, 0) >= :min_objects
           AND COALESCE(a.read_only_tables, 0) >= :read_share * a.tables_ AS mostly_reads
  FROM roles r
  LEFT JOIN agg a ON a.role_name = r.role_name
  LEFT JOIN holders h ON h.role_name = r.role_name
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, role_name, name_says_read, mostly_reads, tables_ AS tables,
       read_only_tables, write_objects, users, example_path,
       IFF(write_objects > 0,
           IFF(name_says_read, 'name says read-only', 'only reads ' || read_only_tables || ' of ' || tables_ || ' tables')
             || ' but can change ' || write_objects || IFF(write_objects = 1, ' object', ' objects'), NULL) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(write_objects > 0, 'WARN', 'OK') AS status
FROM s
WHERE name_says_read OR (mostly_reads AND write_objects > 0)
ORDER BY CASE status WHEN 'WARN' THEN 0 ELSE 1 END, users DESC, role_name
