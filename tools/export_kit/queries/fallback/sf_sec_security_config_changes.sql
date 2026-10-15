-- query_id: sf_sec_security_config_changes
-- shims: QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions QUERY_HISTORY
-- fallback_note: queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
WITH q AS (
  SELECT user_name, role_name, query_type, start_time,
         UPPER(REGEXP_REPLACE(LEFT(query_text, 2000), '\\s+', ' ')) AS t
  FROM __SHIM_QUERY_HISTORY__
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
