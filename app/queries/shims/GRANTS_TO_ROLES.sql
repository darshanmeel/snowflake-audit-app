-- shim: GRANTS_TO_ROLES
-- reads: SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role)
-- each: role, database_role
-- show: SHOW GRANTS TO __ITEM_KIND__ __ITEM__
-- needs: MANAGE GRANTS
-- note: current grants to account and database roles; no inherited or future grants
-- columns: CREATED_ON TIMESTAMP_LTZ(6), MODIFIED_ON TIMESTAMP_LTZ(6), PRIVILEGE VARCHAR, GRANTED_ON VARCHAR, NAME VARCHAR, TABLE_CATALOG VARCHAR, TABLE_SCHEMA VARCHAR, GRANTED_TO VARCHAR, GRANTEE_NAME VARCHAR, GRANT_OPTION BOOLEAN, GRANTED_BY VARCHAR, DELETED_ON TIMESTAMP_LTZ(6), GRANTED_BY_ROLE_TYPE VARCHAR, OBJECT_INSTANCE VARCHAR, IS_INHERITED BOOLEAN, INHERITED_FROM VARCHAR, INHERITED_FROM_DATABASE VARCHAR, INHERITED_FROM_SCHEMA VARCHAR
-- GRANTS_TO_ROLES rebuilt from SHOW GRANTS TO ROLE and SHOW GRANTS TO DATABASE ROLE (per role): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created_on,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS modified_on,
       CAST("privilege" AS VARCHAR) AS privilege,
       CAST("granted_on" AS VARCHAR) AS granted_on,
       CAST(REPLACE(TRIM(name_parts[ARRAY_SIZE(name_parts) - 1]::STRING, '"'), '""', '"') AS VARCHAR) AS name,
       CAST(IFF(ARRAY_SIZE(name_parts) >= 2, REPLACE(TRIM(name_parts[0]::STRING, '"'), '""', '"'), NULL) AS VARCHAR) AS table_catalog,
       CAST(IFF(ARRAY_SIZE(name_parts) >= 3, REPLACE(TRIM(name_parts[1]::STRING, '"'), '""', '"'), NULL) AS VARCHAR) AS table_schema,
       CAST(REPLACE("granted_to", ' ', '_') AS VARCHAR) AS granted_to,
       CAST("grantee_name" AS VARCHAR) AS grantee_name,
       CAST(TRY_TO_BOOLEAN("grant_option"::STRING) AS BOOLEAN) AS grant_option,
       CAST("granted_by" AS VARCHAR) AS granted_by,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted_on,
       CAST(NULL AS VARCHAR) AS granted_by_role_type,
       CAST(NULL AS VARCHAR) AS object_instance,
       CAST(NULL AS BOOLEAN) AS is_inherited,
       CAST(NULL AS VARCHAR) AS inherited_from,
       CAST(NULL AS VARCHAR) AS inherited_from_database,
       CAST(NULL AS VARCHAR) AS inherited_from_schema
FROM (SELECT *, REGEXP_SUBSTR_ALL("name", '"([^"]|"")*"|[^.]+') AS name_parts FROM __SHOW__)
