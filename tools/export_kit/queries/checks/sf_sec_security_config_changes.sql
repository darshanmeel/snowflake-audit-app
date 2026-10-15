-- query_id: sf_sec_security_config_changes
-- title: Who changed users, roles, grants and security policies
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one person x role x kind of security change run successfully in the window
--   (users, roles, grants, network / password / session / authentication policies, security
--   integrations, account parameters, MFA bypass, passwords set by an admin). statements counts them;
--   statement text is never shown because ALTER USER can carry a password.
-- healthy: status = OK for routine user, role and grant administration done under USERADMIN /
--   SECURITYADMIN.
-- investigate_if: WARN for ALTER ACCOUNT, policy or security-integration changes, passwords set with
--   ALTER USER, and user/role admin run under ACCOUNTADMIN; CRITICAL when MFA was bypassed or disabled
--   or a network policy was unset.
-- actions: 1) confirm each CRITICAL change with the person who ran it (free); 2) do day-to-day user and
--   grant work under USERADMIN / SECURITYADMIN, not ACCOUNTADMIN (free); 3) manage users and grants as
--   code or via SCIM so manual changes stand out (config)
-- next: none
-- caveats: classified from the statement text (comments and odd spacing can hide a match); only
--   successful statements; QUERY_HISTORY lags up to 45 minutes.
WITH q AS (
  SELECT user_name, role_name, query_type, start_time,
         UPPER(REGEXP_REPLACE(LEFT(query_text, 2000), '\\s+', ' ')) AS t
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND execution_status = 'SUCCESS'
    AND query_type NOT IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'COPY', 'UNLOAD', 'SHOW',
                           'DESCRIBE', 'USE', 'ALTER_SESSION', 'CREATE_TABLE_AS_SELECT', 'CALL',
                           'EXECUTE_STREAMLIT', 'PUT_FILES', 'GET_FILES', 'LIST_FILES', 'COMMIT', 'BEGIN_TRANSACTION')
),
c AS (
  SELECT q.*,
         CASE
           WHEN t LIKE '%MINS_TO_BYPASS_MFA%' OR t LIKE '%DISABLE_MFA%' OR t LIKE '%MFA%UNENROLL%' THEN 'mfa_bypass'
           WHEN t LIKE 'ALTER ACCOUNT%UNSET%NETWORK_POLICY%' OR t LIKE 'ALTER USER%UNSET%NETWORK_POLICY%' THEN 'network_policy_unset'
           WHEN t LIKE 'ALTER USER%SET%PASSWORD%=%' AND t NOT LIKE '%MUST_CHANGE_PASSWORD%' THEN 'password_set'
           WHEN t LIKE '%NETWORK POLICY%' OR t LIKE '%NETWORK RULE%' OR t LIKE 'ALTER ACCOUNT%NETWORK_POLICY%' THEN 'network_policy'
           WHEN t LIKE '%PASSWORD POLICY%' OR t LIKE '%SESSION POLICY%' OR t LIKE '%AUTHENTICATION POLICY%' THEN 'auth_policy'
           WHEN t LIKE '%SECURITY INTEGRATION%' THEN 'security_integration'
           WHEN t LIKE '%MASKING POLICY%' OR t LIKE '%ROW ACCESS POLICY%' THEN 'data_policy'
           WHEN t LIKE 'ALTER ACCOUNT%' THEN 'account_parameter'
           WHEN REGEXP_LIKE(t, '^(CREATE (OR REPLACE )?|DROP |ALTER )USER .*') THEN 'user_admin'
           WHEN REGEXP_LIKE(t, '^(CREATE (OR REPLACE )?|DROP )(DATABASE )?ROLE .*') THEN 'role_admin'
           WHEN t LIKE 'GRANT %' OR t LIKE 'REVOKE %' THEN 'grant'
         END AS change_kind
  FROM q
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, role_name, change_kind,
       COUNT(*) AS statements, LISTAGG(DISTINCT query_type, ', ') AS query_types,
       MIN(start_time) AS first_change, MAX(start_time) AS last_change,
       COUNT(*) || ' ' || change_kind || ' statements as ' || role_name AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN change_kind IN ('mfa_bypass', 'network_policy_unset') THEN 'CRITICAL'
         WHEN change_kind IN ('password_set', 'network_policy', 'auth_policy', 'security_integration', 'account_parameter', 'data_policy')
           THEN 'WARN'
         WHEN role_name = 'ACCOUNTADMIN' THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM c
WHERE change_kind IS NOT NULL
GROUP BY user_name, role_name, change_kind
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, statements DESC
