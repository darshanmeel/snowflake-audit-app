-- query_id: sf_obj_udfs_procedures
-- shims: FUNCTIONS, PROCEDURES, QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions FUNCTIONS (view, per database), PROCEDURES (view, QUERY_HISTORY
-- fallback_note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
WITH o AS (
  SELECT 'FUNCTION' AS object_type, TO_VARCHAR(function_id) AS object_id, function_catalog AS database_name,
         function_schema AS schema_name, function_name AS object_name, argument_signature,
         function_owner AS object_owner, UPPER(function_language) AS language, runtime_version,
         is_external = 'YES' AS is_external_function,
         NULLIF(ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           NULLIF(TO_VARCHAR(external_access_integrations), ''), api_integration), ', '), '') AS external_access,
         created, last_altered
  FROM __SHIM_FUNCTIONS__
  WHERE deleted IS NULL
  UNION ALL
  -- PROCEDURES has no id column, so the object id is built from its full signature.
  SELECT 'PROCEDURE', procedure_catalog || '.' || procedure_schema || '.' || procedure_name || argument_signature, procedure_catalog, procedure_schema, procedure_name,
         argument_signature, procedure_owner, UPPER(procedure_language), runtime_version,
         FALSE,
         NULLIF(TO_VARCHAR(external_access_integrations), ''),
         created, last_altered
  FROM __SHIM_PROCEDURES__
  WHERE deleted IS NULL
),
-- The procedure name is the last dotted part after CALL, without quotes.
calls AS (
  SELECT UPPER(REPLACE(REGEXP_SUBSTR(
           REGEXP_SUBSTR(query_text, 'call\\s+([^\\s(]+)', 1, 1, 'ie', 1), '[^.]+$'), '"', '')) AS proc_name,
         COUNT(*) AS calls, MAX(start_time) AS last_call
  FROM __SHIM_QUERY_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type = 'CALL'
  GROUP BY 1
),
j AS (
  SELECT o.*,
         o.object_owner IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN') AS admin_owner,
         (o.external_access IS NOT NULL OR o.is_external_function) AS network_access,
         o.language = 'PYTHON' AND o.runtime_version = '3.8' AS runtime_unsupported,
         o.language = 'PYTHON' AND o.runtime_version = '3.9' AS runtime_ending,
         IFF(o.object_type = 'PROCEDURE', COALESCE(c.calls, 0), NULL) AS calls, c.last_call,
         (o.object_type = 'PROCEDURE' AND c.proc_name IS NULL
          AND o.created < DATEADD(day, -:period_days, __AS_OF_DATE__)) AS not_called
  FROM o LEFT JOIN calls c ON o.object_type = 'PROCEDURE' AND c.proc_name = UPPER(o.object_name)
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       object_type, object_id, database_name || '.' || schema_name || '.' || object_name AS object_fqn,
       database_name, schema_name, object_name, argument_signature, object_owner, language, runtime_version,
       is_external_function, external_access, network_access, admin_owner, created, last_altered,
       calls, last_call, not_called,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(runtime_unsupported, 'Python 3.8 runtime is out of support', NULL),
         IFF(runtime_ending, 'Python 3.9 runtime is nearing end of support', NULL),
         IFF(network_access, 'can reach the network via ' || COALESCE(external_access, 'an external function'), NULL),
         IFF(admin_owner, 'owned by ' || object_owner, NULL),
         IFF(not_called, 'no CALL in ' || :period_days || ' days', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN runtime_unsupported OR (network_access AND admin_owner) THEN 'CRITICAL'
         WHEN runtime_ending OR network_access OR admin_owner THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, object_fqn
