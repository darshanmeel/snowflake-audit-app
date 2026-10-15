-- shim: FILE_FORMATS
-- reads: INFORMATION_SCHEMA.FILE_FORMATS (view, per database)
-- each: database
-- note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- columns: FILE_FORMAT_ID VARCHAR, FILE_FORMAT_NAME VARCHAR, FILE_FORMAT_SCHEMA_ID VARCHAR, FILE_FORMAT_SCHEMA VARCHAR, FILE_FORMAT_CATALOG_ID VARCHAR, FILE_FORMAT_CATALOG VARCHAR, FILE_FORMAT_OWNER VARCHAR, FILE_FORMAT_TYPE VARCHAR, RECORD_DELIMITER VARCHAR, FIELD_DELIMITER VARCHAR, SKIP_HEADER NUMBER(38,0), DATE_FORMAT VARCHAR, TIME_FORMAT VARCHAR, TIMESTAMP_FORMAT VARCHAR, BINARY_FORMAT VARCHAR, ESCAPE VARCHAR, ESCAPE_UNENCLOSED_FIELD VARCHAR, TRIM_SPACE BOOLEAN, FIELD_OPTIONALLY_ENCLOSED_BY VARCHAR, NULL_IF VARCHAR, COMPRESSION VARCHAR, ERROR_ON_COLUMN_COUNT_MISMATCH BOOLEAN, CREATED TIMESTAMP_LTZ(6), LAST_ALTERED TIMESTAMP_LTZ(6), DELETED TIMESTAMP_LTZ(6), COMMENT VARCHAR, OWNER_ROLE_TYPE VARCHAR
-- FILE_FORMATS rebuilt from INFORMATION_SCHEMA.FILE_FORMATS (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT file_format_catalog || '.' || file_format_schema || '.' || file_format_name AS file_format_id,
       CAST(file_format_name AS VARCHAR) AS file_format_name,
       file_format_catalog || '.' || file_format_schema AS file_format_schema_id,
       CAST(file_format_schema AS VARCHAR) AS file_format_schema,
       file_format_catalog AS file_format_catalog_id,
       CAST(file_format_catalog AS VARCHAR) AS file_format_catalog,
       CAST(file_format_owner AS VARCHAR) AS file_format_owner,
       CAST(file_format_type AS VARCHAR) AS file_format_type,
       CAST(record_delimiter AS VARCHAR) AS record_delimiter,
       CAST(field_delimiter AS VARCHAR) AS field_delimiter,
       CAST(skip_header AS NUMBER(38,0)) AS skip_header,
       CAST(date_format AS VARCHAR) AS date_format,
       CAST(time_format AS VARCHAR) AS time_format,
       CAST(timestamp_format AS VARCHAR) AS timestamp_format,
       CAST(binary_format AS VARCHAR) AS binary_format,
       CAST(escape AS VARCHAR) AS escape,
       CAST(escape_unenclosed_field AS VARCHAR) AS escape_unenclosed_field,
       CAST(trim_space AS BOOLEAN) AS trim_space,
       CAST(field_optionally_enclosed_by AS VARCHAR) AS field_optionally_enclosed_by,
       CAST(null_if AS VARCHAR) AS null_if,
       CAST(compression AS VARCHAR) AS compression,
       CAST(error_on_column_count_mismatch AS BOOLEAN) AS error_on_column_count_mismatch,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(comment AS VARCHAR) AS comment,
       CAST(NULL AS VARCHAR) AS owner_role_type
FROM __ITEM__.INFORMATION_SCHEMA.FILE_FORMATS
