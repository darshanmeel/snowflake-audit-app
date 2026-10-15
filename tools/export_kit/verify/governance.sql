-- Test queries: Access, Audit, PII and Lineage. Read-only (SELECT and WITH only); paste one at a time
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
