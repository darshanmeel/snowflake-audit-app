-- shim: PIPES
-- reads: INFORMATION_SCHEMA.PIPES (view, per database)
-- each: database
-- note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- columns: PIPE_ID VARCHAR, PIPE_NAME VARCHAR, PIPE_SCHEMA_ID VARCHAR, PIPE_SCHEMA VARCHAR, PIPE_CATALOG_ID VARCHAR, PIPE_CATALOG VARCHAR, IS_AUTOINGEST_ENABLED VARCHAR, NOTIFICATION_CHANNEL_NAME VARCHAR, PIPE_OWNER VARCHAR, DEFINITION VARCHAR, CREATED TIMESTAMP_LTZ(6), LAST_ALTERED TIMESTAMP_LTZ(6), COMMENT VARCHAR, PATTERN VARCHAR, DELETED TIMESTAMP_LTZ(6), OWNER_ROLE_TYPE VARCHAR, IS_SNOWFLAKE_MANAGED BOOLEAN
-- PIPES rebuilt from INFORMATION_SCHEMA.PIPES (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT pipe_catalog || '.' || pipe_schema || '.' || pipe_name AS pipe_id,
       CAST(pipe_name AS VARCHAR) AS pipe_name,
       pipe_catalog || '.' || pipe_schema AS pipe_schema_id,
       CAST(pipe_schema AS VARCHAR) AS pipe_schema,
       pipe_catalog AS pipe_catalog_id,
       CAST(pipe_catalog AS VARCHAR) AS pipe_catalog,
       CAST(is_autoingest_enabled AS VARCHAR) AS is_autoingest_enabled,
       CAST(notification_channel_name AS VARCHAR) AS notification_channel_name,
       CAST(pipe_owner AS VARCHAR) AS pipe_owner,
       CAST(definition AS VARCHAR) AS definition,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(comment AS VARCHAR) AS comment,
       CAST(pattern AS VARCHAR) AS pattern,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(NULL AS VARCHAR) AS owner_role_type,
       CAST(NULL AS BOOLEAN) AS is_snowflake_managed
FROM __ITEM__.INFORMATION_SCHEMA.PIPES
