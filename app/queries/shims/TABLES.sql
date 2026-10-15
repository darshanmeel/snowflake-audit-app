-- shim: TABLES
-- reads: INFORMATION_SCHEMA.TABLES (view, per database)
-- each: database
-- note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- columns: TABLE_ID VARCHAR, TABLE_NAME VARCHAR, TABLE_SCHEMA_ID VARCHAR, TABLE_SCHEMA VARCHAR, TABLE_CATALOG_ID VARCHAR, TABLE_CATALOG VARCHAR, TABLE_OWNER VARCHAR, TABLE_TYPE VARCHAR, IS_TRANSIENT VARCHAR, IS_ICEBERG VARCHAR, IS_DYNAMIC VARCHAR, IS_HYBRID VARCHAR, CLUSTERING_KEY VARCHAR, ROW_COUNT NUMBER(38,0), BYTES NUMBER(38,0), RETENTION_TIME NUMBER(38,0), SELF_REFERENCING_COLUMN_NAME VARCHAR, REFERENCE_GENERATION VARCHAR, USER_DEFINED_TYPE_CATALOG VARCHAR, USER_DEFINED_TYPE_SCHEMA VARCHAR, USER_DEFINED_TYPE_NAME VARCHAR, IS_INSERTABLE_INTO VARCHAR, IS_TYPED VARCHAR, COMMIT_ACTION VARCHAR, CREATED TIMESTAMP_LTZ(6), LAST_ALTERED TIMESTAMP_LTZ(6), LAST_DDL TIMESTAMP_LTZ(6), LAST_DDL_BY VARCHAR, DELETED TIMESTAMP_LTZ(6), AUTO_CLUSTERING_ON VARCHAR, COMMENT VARCHAR, OWNER_ROLE_TYPE VARCHAR, INSTANCE_ID NUMBER(38,0), ARCHIVE_STORAGE_COOL_ROW_COUNT NUMBER(38,0), ARCHIVE_STORAGE_COOL_BYTES NUMBER(38,0), ARCHIVE_STORAGE_COLD_ROW_COUNT NUMBER(38,0), ARCHIVE_STORAGE_COLD_BYTES NUMBER(38,0), ERROR_LOGGING VARCHAR
-- TABLES rebuilt from INFORMATION_SCHEMA.TABLES (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT table_catalog || '.' || table_schema || '.' || table_name AS table_id,
       CAST(table_name AS VARCHAR) AS table_name,
       table_catalog || '.' || table_schema AS table_schema_id,
       CAST(table_schema AS VARCHAR) AS table_schema,
       table_catalog AS table_catalog_id,
       CAST(table_catalog AS VARCHAR) AS table_catalog,
       CAST(table_owner AS VARCHAR) AS table_owner,
       CAST(table_type AS VARCHAR) AS table_type,
       CAST(is_transient AS VARCHAR) AS is_transient,
       CAST(is_iceberg AS VARCHAR) AS is_iceberg,
       CAST(is_dynamic AS VARCHAR) AS is_dynamic,
       CAST(is_hybrid AS VARCHAR) AS is_hybrid,
       CAST(clustering_key AS VARCHAR) AS clustering_key,
       CAST(row_count AS NUMBER(38,0)) AS row_count,
       CAST(bytes AS NUMBER(38,0)) AS bytes,
       CAST(retention_time AS NUMBER(38,0)) AS retention_time,
       CAST(self_referencing_column_name AS VARCHAR) AS self_referencing_column_name,
       CAST(reference_generation AS VARCHAR) AS reference_generation,
       CAST(user_defined_type_catalog AS VARCHAR) AS user_defined_type_catalog,
       CAST(user_defined_type_schema AS VARCHAR) AS user_defined_type_schema,
       CAST(user_defined_type_name AS VARCHAR) AS user_defined_type_name,
       CAST(is_insertable_into AS VARCHAR) AS is_insertable_into,
       CAST(is_typed AS VARCHAR) AS is_typed,
       CAST(commit_action AS VARCHAR) AS commit_action,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(last_ddl AS TIMESTAMP_LTZ(6)) AS last_ddl,
       CAST(last_ddl_by AS VARCHAR) AS last_ddl_by,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(auto_clustering_on AS VARCHAR) AS auto_clustering_on,
       CAST(comment AS VARCHAR) AS comment,
       CAST(NULL AS VARCHAR) AS owner_role_type,
       CAST(NULL AS NUMBER(38,0)) AS instance_id,
       CAST(NULL AS NUMBER(38,0)) AS archive_storage_cool_row_count,
       CAST(NULL AS NUMBER(38,0)) AS archive_storage_cool_bytes,
       CAST(NULL AS NUMBER(38,0)) AS archive_storage_cold_row_count,
       CAST(NULL AS NUMBER(38,0)) AS archive_storage_cold_bytes,
       CAST(error_logging AS VARCHAR) AS error_logging
FROM __ITEM__.INFORMATION_SCHEMA.TABLES
WHERE is_temporary = 'NO'
