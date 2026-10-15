-- shim: STAGES
-- reads: INFORMATION_SCHEMA.STAGES (view, per database)
-- each: database
-- note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- columns: STAGE_ID VARCHAR, STAGE_NAME VARCHAR, STAGE_SCHEMA_ID VARCHAR, STAGE_SCHEMA VARCHAR, STAGE_CATALOG_ID VARCHAR, STAGE_CATALOG VARCHAR, STAGE_URL VARCHAR, STAGE_REGION VARCHAR, STAGE_TYPE VARCHAR, STAGE_OWNER VARCHAR, COMMENT VARCHAR, CREATED TIMESTAMP_LTZ(6), LAST_ALTERED TIMESTAMP_LTZ(6), DELETED TIMESTAMP_LTZ(6), OWNER_ROLE_TYPE VARCHAR, INSTANCE_ID NUMBER(38,0), ENDPOINT VARCHAR, DIRECTORY_ENABLED BOOLEAN, STORAGE_INTEGRATION VARCHAR
-- STAGES rebuilt from INFORMATION_SCHEMA.STAGES (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT stage_catalog || '.' || stage_schema || '.' || stage_name AS stage_id,
       CAST(stage_name AS VARCHAR) AS stage_name,
       stage_catalog || '.' || stage_schema AS stage_schema_id,
       CAST(stage_schema AS VARCHAR) AS stage_schema,
       stage_catalog AS stage_catalog_id,
       CAST(stage_catalog AS VARCHAR) AS stage_catalog,
       CAST(stage_url AS VARCHAR) AS stage_url,
       CAST(stage_region AS VARCHAR) AS stage_region,
       CAST(stage_type AS VARCHAR) AS stage_type,
       CAST(stage_owner AS VARCHAR) AS stage_owner,
       CAST(comment AS VARCHAR) AS comment,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(NULL AS VARCHAR) AS owner_role_type,
       CAST(NULL AS NUMBER(38,0)) AS instance_id,
       CAST(endpoint AS VARCHAR) AS endpoint,
       CAST(directory_enabled AS BOOLEAN) AS directory_enabled,
       CAST(NULL AS VARCHAR) AS storage_integration
FROM __ITEM__.INFORMATION_SCHEMA.STAGES
