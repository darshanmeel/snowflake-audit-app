-- Live views, stages, functions, procedures, pipes and tasks, one row per object, outside the SNOWFLAKE
-- database. inv has object_key: the id, or the name for a procedure, whose overloads merge into one row.
-- inv_fqn maps a name to its key, for events without an object id.
inv0 AS (
  SELECT 'VIEW' AS object_domain, IFF(is_secure = 'YES', 'secure', CAST(NULL AS VARCHAR)) AS object_subtype,
         table_catalog AS database_name, table_schema AS schema_name, table_name AS object_name,
         TO_VARCHAR(table_id) AS object_id, table_owner AS object_owner, created, last_ddl AS last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.VIEWS
  WHERE deleted IS NULL AND table_catalog <> 'SNOWFLAKE'
  UNION ALL
  SELECT 'STAGE', stage_type, stage_catalog, stage_schema, stage_name, TO_VARCHAR(stage_id), stage_owner,
         created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.STAGES
  WHERE deleted IS NULL AND stage_catalog <> 'SNOWFLAKE'
  UNION ALL
  SELECT 'FUNCTION', function_language, function_catalog, function_schema, function_name,
         TO_VARCHAR(function_id), function_owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS
  WHERE deleted IS NULL AND function_catalog <> 'SNOWFLAKE'
  UNION ALL
  -- no id: one row per name, overloads merged
  SELECT 'PROCEDURE', MAX(procedure_language), procedure_catalog, procedure_schema, procedure_name,
         CAST(NULL AS VARCHAR), MAX(procedure_owner), MIN(created), MAX(last_altered)
  FROM SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES
  WHERE deleted IS NULL AND procedure_catalog <> 'SNOWFLAKE'
  GROUP BY procedure_catalog, procedure_schema, procedure_name
  UNION ALL
  SELECT 'PIPE', CAST(NULL AS VARCHAR), pipe_catalog, pipe_schema, pipe_name, TO_VARCHAR(pipe_id),
         pipe_owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPES
  WHERE deleted IS NULL AND pipe_catalog <> 'SNOWFLAKE'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY pipe_id ORDER BY last_altered DESC) = 1
  UNION ALL
  SELECT 'TASK', state, task_database, task_schema, task_name, TO_VARCHAR(id), task_owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASKS
  WHERE deleted IS NULL AND task_database <> 'SNOWFLAKE'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY last_altered DESC) = 1
),
inv AS (
  SELECT object_domain, object_subtype, database_name, schema_name, object_name, object_id, object_owner,
         created, last_altered,
         UPPER(database_name || '.' || schema_name || '.' || object_name) AS object_fqn,
         IFF(object_domain = 'PROCEDURE', UPPER(database_name || '.' || schema_name || '.' || object_name),
             object_id) AS object_key
  FROM inv0
),
inv_fqn AS (
  -- name fallback for events without an object id; overloads share a name, so one key per name
  SELECT object_domain, object_fqn, MIN(object_key) AS object_key
  FROM inv
  GROUP BY 1, 2
)
