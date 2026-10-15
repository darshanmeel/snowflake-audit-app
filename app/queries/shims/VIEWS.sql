-- shim: VIEWS
-- reads: INFORMATION_SCHEMA.VIEWS (view, per database)
-- each: database
-- note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- columns: TABLE_ID VARCHAR, TABLE_NAME VARCHAR, TABLE_SCHEMA_ID VARCHAR, TABLE_SCHEMA VARCHAR, TABLE_CATALOG_ID VARCHAR, TABLE_CATALOG VARCHAR, TABLE_OWNER VARCHAR, VIEW_DEFINITION VARCHAR, CHECK_OPTION VARCHAR, IS_UPDATABLE VARCHAR, INSERTABLE_INTO VARCHAR, IS_SECURE VARCHAR, CREATED TIMESTAMP_LTZ(6), LAST_ALTERED TIMESTAMP_LTZ(6), LAST_DDL TIMESTAMP_LTZ(6), LAST_DDL_BY VARCHAR, DELETED TIMESTAMP_LTZ(6), COMMENT VARCHAR, OWNER_ROLE_TYPE VARCHAR, INSTANCE_ID NUMBER(38,0)
-- VIEWS rebuilt from INFORMATION_SCHEMA.VIEWS (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT table_catalog || '.' || table_schema || '.' || table_name AS table_id,
       CAST(table_name AS VARCHAR) AS table_name,
       table_catalog || '.' || table_schema AS table_schema_id,
       CAST(table_schema AS VARCHAR) AS table_schema,
       table_catalog AS table_catalog_id,
       CAST(table_catalog AS VARCHAR) AS table_catalog,
       CAST(table_owner AS VARCHAR) AS table_owner,
       CAST(view_definition AS VARCHAR) AS view_definition,
       CAST(check_option AS VARCHAR) AS check_option,
       CAST(is_updatable AS VARCHAR) AS is_updatable,
       CAST(insertable_into AS VARCHAR) AS insertable_into,
       CAST(is_secure AS VARCHAR) AS is_secure,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(last_ddl AS TIMESTAMP_LTZ(6)) AS last_ddl,
       CAST(last_ddl_by AS VARCHAR) AS last_ddl_by,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(comment AS VARCHAR) AS comment,
       CAST(NULL AS VARCHAR) AS owner_role_type,
       CAST(NULL AS NUMBER(38,0)) AS instance_id
FROM __ITEM__.INFORMATION_SCHEMA.VIEWS
