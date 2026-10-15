-- shim: TASKS
-- reads: SHOW TASKS
-- show: SHOW TASKS IN ACCOUNT
-- needs: MANAGE GRANTS
-- note: live tasks only; names stand in for database, schema and user ids
-- TASKS rebuilt from SHOW TASKS: each column taken by name, mapped, or NULL where the source has none.
SELECT CAST("created_on" AS TIMESTAMP_NTZ(3)) AS created,
       CAST(NULL AS TIMESTAMP_LTZ(9)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(9)) AS deleted,
       CAST("id" AS VARCHAR) AS id,
       CAST("name" AS VARCHAR) AS task_name,
       "database_name" AS task_database_id,
       CAST("database_name" AS VARCHAR) AS task_database,
       "database_name" || '.' || "schema_name" AS task_schema_id,
       CAST("schema_name" AS VARCHAR) AS task_schema,
       CAST("owner" AS VARCHAR) AS task_owner,
       CAST("comment" AS VARCHAR) AS comment,
       CAST("warehouse" AS VARCHAR) AS warehouse,
       CAST("schedule" AS VARCHAR) AS schedule,
       TRY_PARSE_JSON(TO_VARCHAR("predecessors")) AS predecessors,
       CAST("state" AS VARCHAR) AS state,
       CAST("definition" AS VARCHAR) AS definition,
       CAST("condition" AS VARCHAR) AS condition,
       CAST(TRY_TO_BOOLEAN("allow_overlapping_execution"::STRING) AS BOOLEAN) AS allow_overlapping_execution,
       CAST("error_integration" AS VARCHAR) AS error_integration,
       CAST("last_committed_on" AS TIMESTAMP_NTZ(3)) AS last_committed,
       CAST("last_suspended_on" AS TIMESTAMP_NTZ(3)) AS last_suspended,
       CAST("owner_role_type" AS VARCHAR) AS owner_role_type,
       CAST(NULL AS NUMBER(38,0)) AS instance_id,
       CAST("config" AS VARCHAR) AS config,
       TRY_PARSE_JSON(TO_VARCHAR("task_relations")) AS task_relations,
       CAST(NULL AS OBJECT) AS task_relations_ids,
       CAST("last_suspended_reason" AS VARCHAR) AS last_suspended_reason,
       CAST("success_integration" AS VARCHAR) AS success_integration,
       CAST("scheduling_mode" AS VARCHAR) AS scheduling_mode,
       CAST("target_completion_interval" AS VARCHAR) AS target_completion_interval,
       "execute_as_user" AS execute_as_user_id,
       CAST("overlap_policy" AS VARCHAR) AS overlap_policy,
       "created_by_user" AS created_by_user_id
FROM __SHOW__
