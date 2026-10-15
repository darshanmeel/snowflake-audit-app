-- query_id: sf_secx_login_client_versions
-- shims: LOGIN_HISTORY
-- reads: INFORMATION_SCHEMA table functions LOGIN_HISTORY
-- fallback_note: sign-ins for the last 7 days at most, only the users this role can monitor, up to 10,000 a day
WITH info AS (
  SELECT UPPER(TO_VARCHAR(f.value:clientId)) AS client_id, UPPER(TO_VARCHAR(f.value:clientAppId)) AS client_app_id,
         TO_VARCHAR(f.value:minimumSupportedVersion) AS minimum_supported,
         TO_VARCHAR(f.value:minimumNearingEndOfSupportVersion) AS nearing_end,
         TO_VARCHAR(f.value:recommendedVersion) AS recommended
  FROM (SELECT PARSE_JSON(SYSTEM$CLIENT_VERSION_INFO()) AS j) v,
       LATERAL FLATTEN(input => v.j) f
),
-- REPORTED_CLIENT_TYPE uses its own names; these are the matching client ids in the support table.
map AS (
  SELECT column1 AS client_type, column2 AS client_key
  FROM VALUES ('JDBC_DRIVER', 'JDBC'), ('ODBC_DRIVER', 'ODBC'), ('PYTHON_DRIVER', 'PYTHONCONNECTOR'),
              ('JAVASCRIPT_DRIVER', 'JSDRIVER'), ('GO_DRIVER', 'GO'), ('DOTNET_DRIVER', 'DOTNETDRIVER'),
              ('PHP_DRIVER', 'PHP_PDO'), ('SNOWSQL', 'SNOWSQL'), ('C_DRIVER', 'LIBSNOWFLAKECLIENT'),
              ('SPARK_CONNECTOR', 'SPARK')
),
l AS (
  SELECT UPPER(reported_client_type) AS client_type, reported_client_version AS client_version,
         COUNT(*) AS logins, COUNT(DISTINCT user_name) AS distinct_users, MAX(event_timestamp) AS last_login,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT user_name) WITHIN GROUP (ORDER BY user_name), 0, :max_users_listed), ', ') AS users
  FROM __SHIM_LOGIN_HISTORY__
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
    AND is_success = 'YES'
  GROUP BY 1, 2
),
j AS (
  SELECT l.*, i.minimum_supported, i.nearing_end, i.recommended,
         -- Zero-pad the first three numeric parts so versions compare as text.
         LPAD(COALESCE(REGEXP_SUBSTR(l.client_version, '\\d+', 1, 1), '0'), 6, '0')
           || LPAD(COALESCE(REGEXP_SUBSTR(l.client_version, '\\d+', 1, 2), '0'), 6, '0')
           || LPAD(COALESCE(REGEXP_SUBSTR(l.client_version, '\\d+', 1, 3), '0'), 6, '0') AS v_key,
         LPAD(COALESCE(REGEXP_SUBSTR(i.minimum_supported, '\\d+', 1, 1), '0'), 6, '0')
           || LPAD(COALESCE(REGEXP_SUBSTR(i.minimum_supported, '\\d+', 1, 2), '0'), 6, '0')
           || LPAD(COALESCE(REGEXP_SUBSTR(i.minimum_supported, '\\d+', 1, 3), '0'), 6, '0') AS min_key,
         LPAD(COALESCE(REGEXP_SUBSTR(i.nearing_end, '\\d+', 1, 1), '0'), 6, '0')
           || LPAD(COALESCE(REGEXP_SUBSTR(i.nearing_end, '\\d+', 1, 2), '0'), 6, '0')
           || LPAD(COALESCE(REGEXP_SUBSTR(i.nearing_end, '\\d+', 1, 3), '0'), 6, '0') AS near_key
  FROM l
  LEFT JOIN map m ON m.client_type = l.client_type
  LEFT JOIN info i ON i.client_id = m.client_key OR i.client_app_id = m.client_key
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.client_type, l.client_version ORDER BY i.minimum_supported DESC NULLS LAST) = 1
),
s AS (
  SELECT j.*,
         CASE
           -- Snowsight is served by Snowflake: there is no client to upgrade
           WHEN client_type = 'SNOWFLAKE_UI' THEN 'SNOWFLAKE_MANAGED'
           WHEN minimum_supported IS NULL OR REGEXP_SUBSTR(client_version, '\\d+') IS NULL THEN 'UNKNOWN'
           WHEN v_key < min_key THEN 'UNSUPPORTED'
           WHEN nearing_end IS NOT NULL AND v_key < near_key THEN 'NEARING_END'
           ELSE 'SUPPORTED'
         END AS support_state
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, client_type, client_version, support_state,
       minimum_supported, nearing_end, recommended, logins, distinct_users, users, last_login,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(support_state = 'UNSUPPORTED', 'below minimum supported ' || minimum_supported, NULL),
         IFF(support_state = 'NEARING_END', 'below ' || nearing_end || ', nearing end of support', NULL),
         IFF(support_state IN ('UNSUPPORTED', 'NEARING_END') AND recommended IS NOT NULL,
             'recommended ' || recommended, NULL)), '; ') AS reasons,
       CASE WHEN support_state <> 'UNKNOWN' THEN NULL
            WHEN REGEXP_SUBSTR(client_version, '\\d+') IS NULL THEN 'no version reported by the client'
            ELSE 'no support data for client type ' || COALESCE(client_type, '(none)') END AS not_assessed_reason,
       CASE support_state WHEN 'UNSUPPORTED' THEN 'CRITICAL' WHEN 'NEARING_END' THEN 'WARN'
                          WHEN 'UNKNOWN' THEN 'NOT_ASSESSED' ELSE 'OK' END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END,
         distinct_users DESC, client_type, client_version
