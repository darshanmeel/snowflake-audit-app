-- shim: SCHEMATA
-- reads: INFORMATION_SCHEMA.SCHEMATA (view, per database)
-- each: database
-- note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- columns: SCHEMA_ID VARCHAR, SCHEMA_NAME VARCHAR, CATALOG_ID VARCHAR, CATALOG_NAME VARCHAR, SCHEMA_OWNER VARCHAR, RETENTION_TIME NUMBER(38,0), IS_TRANSIENT VARCHAR, IS_MANAGED_ACCESS VARCHAR, DEFAULT_CHARACTER_SET_CATALOG VARCHAR, DEFAULT_CHARACTER_SET_SCHEMA VARCHAR, DEFAULT_CHARACTER_SET_NAME VARCHAR, SQL_PATH VARCHAR, COMMENT VARCHAR, CREATED TIMESTAMP_LTZ(6), LAST_ALTERED TIMESTAMP_LTZ(6), DELETED TIMESTAMP_LTZ(6), OWNER_ROLE_TYPE VARCHAR, SCHEMA_TYPE VARCHAR, VERSION_NAME VARCHAR, VERSIONED_SCHEMA_ID NUMBER(38,0), OBJECT_VISIBILITY OBJECT, REPLICABLE_WITH_FAILOVER_GROUPS VARCHAR
-- SCHEMATA rebuilt from INFORMATION_SCHEMA.SCHEMATA (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT catalog_name || '.' || schema_name AS schema_id,
       CAST(schema_name AS VARCHAR) AS schema_name,
       catalog_name AS catalog_id,
       CAST(catalog_name AS VARCHAR) AS catalog_name,
       CAST(schema_owner AS VARCHAR) AS schema_owner,
       CAST(retention_time AS NUMBER(38,0)) AS retention_time,
       CAST(is_transient AS VARCHAR) AS is_transient,
       CAST(is_managed_access AS VARCHAR) AS is_managed_access,
       CAST(default_character_set_catalog AS VARCHAR) AS default_character_set_catalog,
       CAST(default_character_set_schema AS VARCHAR) AS default_character_set_schema,
       CAST(default_character_set_name AS VARCHAR) AS default_character_set_name,
       CAST(sql_path AS VARCHAR) AS sql_path,
       CAST(comment AS VARCHAR) AS comment,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(owner_role_type AS VARCHAR) AS owner_role_type,
       CAST(NULL AS VARCHAR) AS schema_type,
       CAST(NULL AS VARCHAR) AS version_name,
       CAST(NULL AS NUMBER(38,0)) AS versioned_schema_id,
       CAST(NULL AS OBJECT) AS object_visibility,
       CAST(replicable_with_failover_groups AS VARCHAR) AS replicable_with_failover_groups
FROM __ITEM__.INFORMATION_SCHEMA.SCHEMATA
