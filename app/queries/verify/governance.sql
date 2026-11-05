-- Test queries: Access, Audit, PII, Lineage and Activity. Read-only (SELECT and WITH only); paste one at a time
-- into a worksheet. Each recomputes a figure the app shows, straight from SNOWFLAKE.ACCOUNT_USAGE.
-- Only names, counts and flags are read: never policy bodies, IP lists or query text.
-- Change the numbers in the p CTE: days = the window you picked in the app, end_date = the export date.

-- 1. Enabled people with a password and no MFA, and how often they signed in with the password alone
--    (Access; check sf_sec_users_without_mfa).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
l AS (
  SELECT user_name, COUNT_IF(is_success = 'YES' AND first_authentication_factor = 'PASSWORD'
                             AND second_authentication_factor IS NULL) AS password_only_logins
  FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY, p
  WHERE event_timestamp >= DATEADD(day, -p.days, p.end_date) AND event_timestamp < p.end_date
  GROUP BY user_name
)
SELECT u.name AS user_name, COALESCE(l.password_only_logins, 0) AS password_only_logins
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS u
LEFT JOIN l ON l.user_name = u.name
WHERE u.deleted_on IS NULL AND COALESCE(UPPER(u.type), 'PERSON') = 'PERSON'
  AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(u.disabled)), FALSE)
  AND COALESCE(u.has_password, FALSE) AND NOT COALESCE(u.has_mfa, FALSE)
  AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(u.ext_authn_duo)), FALSE)
  AND UPPER(u.name) NOT IN ('SNOWFLAKE', 'WORKSHEETS_APP_USER')
ORDER BY password_only_logins DESC;

-- 2. Enabled users with no sign-in for 90 days, or never and created over 90 days ago (Access; check
--    sf_sec_stale_users).
WITH p AS (SELECT CURRENT_DATE() AS end_date)
SELECT name AS user_name, last_success_login, created_on,
       DATEDIFF(day, last_success_login, p.end_date) AS days_since_login
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS, p
WHERE deleted_on IS NULL AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)
  AND COALESCE(UPPER(type), '') <> 'SNOWFLAKE_SERVICE' AND UPPER(name) NOT IN ('SNOWFLAKE', 'WORKSHEETS_APP_USER')
  AND ((last_success_login IS NULL AND DATEDIFF(day, created_on, p.end_date) >= 90)
       OR DATEDIFF(day, last_success_login, p.end_date) >= 90)
ORDER BY days_since_login DESC NULLS FIRST;

-- 3. Failed sign-ins per user name and IP; a failure with no user name is kept (Access; check
--    sf_sec_failed_logins).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT COALESCE(UPPER(user_name), '(no user name)') AS user_name, COALESCE(client_ip, '(no ip)') AS client_ip,
       COUNT_IF(is_success = 'NO') AS failed_logins, COUNT_IF(is_success = 'YES') AS successful_logins
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY, p
WHERE event_timestamp >= DATEADD(day, -p.days, p.end_date) AND event_timestamp < p.end_date
GROUP BY 1, 2
HAVING failed_logins > 0
ORDER BY failed_logins DESC;

-- 4. Privileged grants created or revoked in the window: admin roles, account-level privileges, and
--    ownership of roles, users, integrations, databases, schemas and warehouses (Audit; check
--    sf_sec_privileged_grant_changes).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
ev AS (
  SELECT created_on AS change_time, 'GRANTED' AS change, grantee_name, 'USAGE' AS privilege, 'ROLE' AS granted_on, role AS name
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, p WHERE created_on >= DATEADD(day, -p.days, p.end_date) AND created_on < p.end_date
  UNION ALL
  SELECT deleted_on, 'REVOKED', grantee_name, 'USAGE', 'ROLE', role
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS, p WHERE deleted_on >= DATEADD(day, -p.days, p.end_date) AND deleted_on < p.end_date
  UNION ALL
  SELECT created_on, 'GRANTED', grantee_name, privilege, granted_on, name
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, p WHERE created_on >= DATEADD(day, -p.days, p.end_date) AND created_on < p.end_date
  UNION ALL
  SELECT deleted_on, 'REVOKED', grantee_name, privilege, granted_on, name
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, p WHERE deleted_on >= DATEADD(day, -p.days, p.end_date) AND deleted_on < p.end_date
)
SELECT * FROM ev
WHERE (granted_on = 'ROLE' AND privilege = 'USAGE' AND name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN', 'SYSADMIN'))
   OR granted_on = 'ACCOUNT'
   OR (privilege = 'OWNERSHIP' AND granted_on IN ('ROLE', 'USER', 'INTEGRATION', 'DATABASE', 'SCHEMA', 'WAREHOUSE'))
ORDER BY change_time DESC;

-- 5. Everything the PUBLIC role holds, which every user has (Access; check sf_gov_public_role_grants).
SELECT privilege, granted_on, COALESCE(table_catalog || '.', '') || COALESCE(table_schema || '.', '') || name AS object_fqn,
       grant_option, granted_by
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE grantee_name = 'PUBLIC' AND granted_to IN ('ROLE', 'ACCOUNT ROLE') AND deleted_on IS NULL
ORDER BY granted_on, object_fqn;

-- 6. Columns tagged sensitive, and whether a masking policy is set on the column (PII; check
--    sf_gov_sensitive_columns_unprotected). A mask that reaches a column through a tag shows on the page.
WITH s AS (
  SELECT DISTINCT object_database AS db, object_schema AS sch, object_name AS tbl, column_name AS col
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL AND domain = 'COLUMN'
    AND (tag_name IN ('PRIVACY_CATEGORY', 'SEMANTIC_CATEGORY')
         OR REGEXP_LIKE(UPPER(tag_name), '.*(PII|SENSITIVE|CONFIDENTIAL|PHI|PCI|GDPR|PERSONAL|RESTRICTED).*'))
),
m AS (
  SELECT DISTINCT ref_database_name AS db, ref_schema_name AS sch, ref_entity_name AS tbl, ref_column_name AS col
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  WHERE policy_kind = 'MASKING_POLICY' AND ref_column_name IS NOT NULL
)
SELECT s.db || '.' || s.sch || '.' || s.tbl AS table_fqn, s.col AS column_name, m.col IS NOT NULL AS column_masked
FROM s LEFT JOIN m ON m.db = s.db AND m.sch = s.sch AND m.tbl = s.tbl AND m.col = s.col
ORDER BY column_masked, table_fqn, column_name;

-- 7. Reads, writes and DDL per database in the window, in distinct queries; a query that reads and
--    writes counts in both (Activity > Databases; check sf_use_database_activity). Enterprise edition.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
ah AS (
  SELECT a.* FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY a, p
  WHERE a.query_start_time >= DATEADD(day, -p.days, p.end_date) AND a.query_start_time < p.end_date
),
e AS (
  SELECT a.query_id, a.user_name, 'read' AS kind, UPPER(f.value:"objectName"::STRING) AS object_name
  FROM ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  SELECT a.query_id, a.user_name, 'write', UPPER(f.value:"objectName"::STRING)
  FROM ah a, LATERAL FLATTEN(input => a.objects_modified) f
  UNION ALL
  SELECT a.query_id, a.user_name, 'ddl', UPPER(a.object_modified_by_ddl:"objectName"::STRING)
  FROM ah a WHERE a.object_modified_by_ddl IS NOT NULL
)
SELECT SPLIT_PART(object_name, '.', 1) AS database_name,
       COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
       COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
       COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries,
       COUNT(DISTINCT user_name) AS users
FROM e
WHERE object_name LIKE '%.%'
GROUP BY 1
ORDER BY read_queries + write_queries + ddl_queries DESC;

-- 8. One table, day by day: reads, writes and DDL in distinct queries (Activity > Tables; check
--    sf_use_table_daily). Put the table's DATABASE.SCHEMA.TABLE in the p CTE, upper case.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 'MY_DB.MY_SCHEMA.MY_TABLE' AS table_fqn),
ah AS (
  SELECT a.* FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY a, p
  WHERE a.query_start_time >= DATEADD(day, -p.days, p.end_date) AND a.query_start_time < p.end_date
),
e AS (
  SELECT a.query_id, DATE(a.query_start_time) AS usage_date, 'read' AS kind, UPPER(f.value:"objectName"::STRING) AS object_name
  FROM ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  SELECT a.query_id, DATE(a.query_start_time), 'write', UPPER(f.value:"objectName"::STRING)
  FROM ah a, LATERAL FLATTEN(input => a.objects_modified) f
  UNION ALL
  SELECT a.query_id, DATE(a.query_start_time), 'ddl', UPPER(a.object_modified_by_ddl:"objectName"::STRING)
  FROM ah a WHERE a.object_modified_by_ddl IS NOT NULL
)
SELECT usage_date,
       COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
       COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
       COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries
FROM e, p
WHERE e.object_name = p.table_fqn
GROUP BY usage_date
ORDER BY usage_date;

-- 9. The columns queries filter (WHERE) and join (JOIN) on, per table, and the share of micro-partitions
--    those queries skipped (Activity > Tables; check sf_use_table_columns). GROUP BY is not recorded.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT UPPER(database_name || '.' || schema_name || '.' || table_name) AS table_fqn, UPPER(column_name) AS column_name,
       UPPER(access_type) AS access_type, SUM(num_queries) AS queries,
       ROUND(100 * SUM(partitions_pruned) / NULLIF(SUM(partitions_scanned) + SUM(partitions_pruned), 0), 1) AS prune_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY, p
WHERE interval_start_time >= DATEADD(day, -p.days, p.end_date) AND interval_start_time < p.end_date
  AND UPPER(access_type) IN ('WHERE', 'JOIN') AND column_name IS NOT NULL
GROUP BY 1, 2, 3
ORDER BY table_fqn, access_type DESC, queries DESC;

-- 10. Every role a user can use and the path to it, through the role tree (Access > Explorer; check
--     sf_acc_grant_links). Put the user name in the p CTE. Account roles only: the explorer also counts PUBLIC
--     (every user holds it, with no grant row) and database roles (DATABASE.ROLE), so its count is higher.
WITH RECURSIVE p AS (SELECT 'MY_USER' AS user_name),
walk AS (
  SELECT gu.role AS role_name, 1 AS depth, gu.grantee_name || ' > ' || gu.role AS path
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu, p
  WHERE gu.deleted_on IS NULL AND gu.grantee_name = p.user_name
  UNION ALL
  SELECT g.name, w.depth + 1, w.path || ' > ' || g.name
  FROM walk w
  JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
    ON g.grantee_name = w.role_name AND g.granted_on = 'ROLE' AND g.privilege = 'USAGE'
   AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE') AND g.deleted_on IS NULL
  WHERE w.depth < 20
)
SELECT role_name, MIN(depth) AS shortest_depth, MIN_BY(path, depth) AS shortest_path, COUNT(*) AS paths
FROM walk
GROUP BY role_name
ORDER BY shortest_depth, role_name;

-- 11. Who can read one table: users holding SELECT or OWNERSHIP on it through any role, PUBLIC included
--     (Access > Explorer, object view; check sf_acc_sensitive_reach counts the same for sensitive tables).
--     Put the table in the p CTE, upper case.
WITH RECURSIVE p AS (SELECT 'MY_DB' AS db, 'MY_SCHEMA' AS sch, 'MY_TABLE' AS tbl),
holders AS (
  SELECT DISTINCT g.grantee_name AS role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g, p
  WHERE g.deleted_on IS NULL AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE') AND g.privilege IN ('SELECT', 'OWNERSHIP')
    AND UPPER(g.table_catalog) = p.db AND UPPER(g.table_schema) = p.sch AND UPPER(g.name) = p.tbl
),
up AS (
  SELECT role_name FROM holders
  UNION ALL
  SELECT g.grantee_name
  FROM up
  JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
    ON g.name = up.role_name AND g.granted_on = 'ROLE' AND g.privilege = 'USAGE'
   AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE') AND g.deleted_on IS NULL
)
SELECT u.name AS user_name, COALESCE(UPPER(u.type), 'PERSON') AS user_type,
       COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(u.disabled)), FALSE) AS is_disabled, u.last_success_login
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS u
WHERE u.deleted_on IS NULL
  AND (EXISTS (SELECT 1 FROM up WHERE up.role_name = 'PUBLIC')
       OR EXISTS (SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu
                  JOIN up ON up.role_name = gu.role
                  WHERE gu.deleted_on IS NULL AND gu.grantee_name = u.name))
ORDER BY is_disabled DESC, user_name;

-- 12. Disabled users that still hold roles (Access > Users & sign-ins; check sf_acc_disabled_users_roles).
SELECT u.name AS user_name, COUNT(DISTINCT gu.role) AS direct_roles,
       LISTAGG(DISTINCT gu.role, ', ') WITHIN GROUP (ORDER BY gu.role) AS roles
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS u
JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu ON gu.grantee_name = u.name AND gu.deleted_on IS NULL
WHERE u.deleted_on IS NULL AND COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(u.disabled)), FALSE)
GROUP BY u.name
ORDER BY direct_roles DESC, user_name;

-- 13. One table: how the queries on it run, per day on average, and its top 10 query shapes by total time
--     (Activity > Tables; checks sf_use_query_profile and sf_use_top_query_shapes). Put the table in the p
--     CTE, upper case. Time, partitions and spill are the whole query's.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 'MY_DB.MY_SCHEMA.MY_TABLE' AS table_fqn),
q AS (
  SELECT DISTINCT a.query_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY a, p,
       LATERAL FLATTEN(input => ARRAY_CAT(a.base_objects_accessed, a.objects_modified)) f
  WHERE a.query_start_time >= DATEADD(day, -p.days, p.end_date) AND a.query_start_time < p.end_date
    AND UPPER(f.value:"objectName"::STRING) = p.table_fqn
)
SELECT h.query_parameterized_hash AS shape, MAX(h.query_type) AS query_type, COUNT(*) AS runs,
       ROUND(COUNT(*) / MAX(p.days), 1) AS runs_per_day, ROUND(AVG(h.total_elapsed_time) / 1000, 1) AS avg_s,
       ROUND(SUM(h.total_elapsed_time) / 1000) AS total_s, ROUND(AVG(h.partitions_scanned)) AS avg_partitions,
       ROUND(100 * SUM(h.partitions_scanned) / NULLIF(SUM(h.partitions_total), 0), 1) AS scan_pct,
       ROUND(SUM(h.bytes_spilled_to_local_storage + h.bytes_spilled_to_remote_storage) / POWER(1024, 3), 2) AS gb_spilled,
       MAX_BY(h.query_id, h.total_elapsed_time) AS slowest_query_id
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h
JOIN q ON q.query_id = h.query_id, p
WHERE h.start_time >= DATEADD(day, -(p.days + 1), p.end_date)
GROUP BY h.query_parameterized_hash
ORDER BY total_s DESC
LIMIT 10;

-- 14. One query shape's lineage: the tables it read and wrote, and the columns it filtered and joined on
--     (Activity > Tables, a selected top query). Put the shape (query_parameterized_hash) in the p CTE.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 'MY_SHAPE_HASH' AS shape),
t AS (
  SELECT 'reads' AS kind, UPPER(f.value:"objectName"::STRING) AS name, COUNT(DISTINCT a.query_id) AS queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY a
  JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h ON h.query_id = a.query_id, p,
       LATERAL FLATTEN(input => a.base_objects_accessed) f
  WHERE a.query_start_time >= DATEADD(day, -p.days, p.end_date) AND h.start_time >= DATEADD(day, -(p.days + 1), p.end_date)
    AND h.query_parameterized_hash = p.shape
  GROUP BY 1, 2
  UNION ALL
  SELECT 'writes', UPPER(f.value:"objectName"::STRING), COUNT(DISTINCT a.query_id)
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY a
  JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h ON h.query_id = a.query_id, p,
       LATERAL FLATTEN(input => a.objects_modified) f
  WHERE a.query_start_time >= DATEADD(day, -p.days, p.end_date) AND h.start_time >= DATEADD(day, -(p.days + 1), p.end_date)
    AND h.query_parameterized_hash = p.shape
  GROUP BY 1, 2
  UNION ALL
  SELECT UPPER(c.access_type), UPPER(c.table_name || '.' || c.column_name), SUM(c.num_queries)
  FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY c, p
  WHERE c.interval_start_time >= DATEADD(day, -p.days, p.end_date) AND c.query_parameterized_hash = p.shape
    AND UPPER(c.access_type) IN ('WHERE', 'JOIN')
  GROUP BY 1, 2
)
SELECT kind, name, queries FROM t ORDER BY kind, queries DESC;

-- 15. One table, day by day: time per query, waiting per query and partitions skipped (Activity > Tables;
--     check sf_use_table_perf_daily). Put the table in the p CTE, upper case. Time is the whole query's.
WITH p AS (SELECT 'MY_DB' AS db, 'MY_SCHEMA' AS sch, 'MY_TABLE' AS tbl),
q AS (
  SELECT DATE(interval_start_time) AS usage_date, SUM(num_queries) AS queries,
         SUM(aggregate_query_execution_time) / 1000 / NULLIF(SUM(num_queries), 0) AS avg_exec_s,
         GREATEST(SUM(aggregate_query_elapsed_time) - SUM(aggregate_query_compilation_time)
                  - SUM(aggregate_query_execution_time), 0) / 1000 / NULLIF(SUM(num_queries), 0) AS avg_wait_s
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY, p
  WHERE database_name = p.db AND schema_name = p.sch AND table_name = p.tbl
    AND interval_start_time >= DATEADD(day, -30, CURRENT_DATE()) AND interval_start_time < CURRENT_DATE()
  GROUP BY 1
),
s AS (
  SELECT DATE(start_time) AS usage_date,
         100 * SUM(partitions_pruned) / NULLIF(SUM(partitions_scanned) + SUM(partitions_pruned), 0) AS prune_pct
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_PRUNING_HISTORY, p
  WHERE database_name = p.db AND schema_name = p.sch AND table_name = p.tbl
    AND start_time >= DATEADD(day, -30, CURRENT_DATE()) AND start_time < CURRENT_DATE()
  GROUP BY 1
)
SELECT COALESCE(q.usage_date, s.usage_date) AS usage_date, q.queries, q.avg_exec_s, q.avg_wait_s, s.prune_pct
FROM q FULL OUTER JOIN s ON s.usage_date = q.usage_date
ORDER BY 1;
