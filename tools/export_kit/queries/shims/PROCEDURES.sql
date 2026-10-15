-- shim: PROCEDURES
-- reads: INFORMATION_SCHEMA.PROCEDURES (view, per database)
-- each: database
-- note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- columns: PROCEDURE_CATALOG VARCHAR, PROCEDURE_SCHEMA VARCHAR, PROCEDURE_NAME VARCHAR, PROCEDURE_OWNER VARCHAR, ARGUMENT_SIGNATURE VARCHAR, DATA_TYPE VARCHAR, CHARACTER_MAXIMUM_LENGTH NUMBER(38,0), CHARACTER_OCTET_LENGTH NUMBER(38,0), NUMERIC_PRECISION NUMBER(38,0), NUMERIC_PRECISION_RADIX NUMBER(2,0), NUMERIC_SCALE NUMBER(38,0), PROCEDURE_LANGUAGE VARCHAR, PROCEDURE_DEFINITION VARCHAR, CREATED TIMESTAMP_LTZ(6), LAST_ALTERED TIMESTAMP_LTZ(6), COMMENT VARCHAR, DELETED TIMESTAMP_LTZ(6), RUNTIME_VERSION VARCHAR, PACKAGES VARCHAR, INSTALLED_PACKAGES VARCHAR, OWNER_ROLE_TYPE VARCHAR, PROCEDURE_SCHEMA_ID VARCHAR, PROCEDURE_CATALOG_ID VARCHAR, SECRETS VARCHAR, EXTERNAL_ACCESS_INTEGRATIONS VARCHAR
-- PROCEDURES rebuilt from INFORMATION_SCHEMA.PROCEDURES (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(procedure_catalog AS VARCHAR) AS procedure_catalog,
       CAST(procedure_schema AS VARCHAR) AS procedure_schema,
       CAST(procedure_name AS VARCHAR) AS procedure_name,
       CAST(procedure_owner AS VARCHAR) AS procedure_owner,
       CAST(argument_signature AS VARCHAR) AS argument_signature,
       CAST(data_type AS VARCHAR) AS data_type,
       CAST(character_maximum_length AS NUMBER(38,0)) AS character_maximum_length,
       CAST(character_octet_length AS NUMBER(38,0)) AS character_octet_length,
       CAST(numeric_precision AS NUMBER(38,0)) AS numeric_precision,
       CAST(numeric_precision_radix AS NUMBER(2,0)) AS numeric_precision_radix,
       CAST(numeric_scale AS NUMBER(38,0)) AS numeric_scale,
       CAST(procedure_language AS VARCHAR) AS procedure_language,
       CAST(procedure_definition AS VARCHAR) AS procedure_definition,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(comment AS VARCHAR) AS comment,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(runtime_version AS VARCHAR) AS runtime_version,
       CAST(packages AS VARCHAR) AS packages,
       CAST(installed_packages AS VARCHAR) AS installed_packages,
       CAST(NULL AS VARCHAR) AS owner_role_type,
       procedure_catalog || '.' || procedure_schema AS procedure_schema_id,
       procedure_catalog AS procedure_catalog_id,
       CAST(secrets AS VARCHAR) AS secrets,
       CAST(external_access_integrations AS VARCHAR) AS external_access_integrations
FROM __ITEM__.INFORMATION_SCHEMA.PROCEDURES
