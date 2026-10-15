-- One row per task (database.schema.task, the key the task checks call task_full_name or job_id).
-- A task runs as its owner role, so owner_role is that role. Dropped tasks stay, so history resolves.
SELECT __ACCOUNT_ID__ AS account_id,
       database_name || '.' || schema_name || '.' || name AS task_full_name,
       name AS task_name, database_name, schema_name, owner AS owner_role,
       TO_VARCHAR(id) AS task_id, TO_VARCHAR(root_task_id) AS root_task_id,
       MAX(IFF(id = root_task_id, database_name || '.' || schema_name || '.' || name, NULL))
         OVER (PARTITION BY root_task_id) AS root_task_full_name
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
QUALIFY ROW_NUMBER() OVER (PARTITION BY database_name, schema_name, name
                           ORDER BY graph_version_created_on DESC) = 1
