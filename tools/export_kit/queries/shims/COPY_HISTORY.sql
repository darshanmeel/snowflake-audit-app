-- shim: COPY_HISTORY
-- reads: INFORMATION_SCHEMA.LOAD_HISTORY (view, per database)
-- each: database
-- note: bulk COPY loads for the last 14 days only, no Snowpipe loads, no file sizes or stage paths, up to 10,000 files a database; only tables this role can see
-- columns: FILE_NAME VARCHAR, STAGE_LOCATION VARCHAR, LAST_LOAD_TIME TIMESTAMP_LTZ(6), ROW_COUNT NUMBER(38,0), ROW_PARSED NUMBER(38,0), FILE_SIZE NUMBER(38,0), FIRST_ERROR_MESSAGE VARCHAR, FIRST_ERROR_LINE_NUMBER NUMBER(38,0), FIRST_ERROR_CHARACTER_POS NUMBER(38,0), FIRST_ERROR_COLUMN_NAME VARCHAR, ERROR_COUNT NUMBER(38,0), ERROR_LIMIT NUMBER(38,0), STATUS VARCHAR, TABLE_ID VARCHAR, TABLE_NAME VARCHAR, TABLE_SCHEMA_ID VARCHAR, TABLE_SCHEMA_NAME VARCHAR, TABLE_CATALOG_ID VARCHAR, TABLE_CATALOG_NAME VARCHAR, PIPE_CATALOG_NAME VARCHAR, PIPE_SCHEMA_NAME VARCHAR, PIPE_NAME VARCHAR, PIPE_RECEIVED_TIME TIMESTAMP_LTZ(6), FIRST_COMMIT_TIME TIMESTAMP_LTZ(6), BYTES_BILLED NUMBER(38,0)
-- COPY_HISTORY rebuilt from INFORMATION_SCHEMA.LOAD_HISTORY (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(file_name AS VARCHAR) AS file_name,
       CAST(NULL AS VARCHAR) AS stage_location,
       CAST(last_load_time AS TIMESTAMP_LTZ(6)) AS last_load_time,
       CAST(row_count AS NUMBER(38,0)) AS row_count,
       CAST(row_parsed AS NUMBER(38,0)) AS row_parsed,
       CAST(NULL AS NUMBER(38,0)) AS file_size,
       CAST(first_error_message AS VARCHAR) AS first_error_message,
       CAST(first_error_line_number AS NUMBER(38,0)) AS first_error_line_number,
       CAST(first_error_character_position AS NUMBER(38,0)) AS first_error_character_pos,
       CAST(first_error_col_name AS VARCHAR) AS first_error_column_name,
       CAST(error_count AS NUMBER(38,0)) AS error_count,
       CAST(error_limit AS NUMBER(38,0)) AS error_limit,
       CAST(status AS VARCHAR) AS status,
       __ITEM_NAME__ || '.' || schema_name || '.' || table_name AS table_id,
       CAST(table_name AS VARCHAR) AS table_name,
       __ITEM_NAME__ || '.' || schema_name AS table_schema_id,
       CAST(schema_name AS VARCHAR) AS table_schema_name,
       __ITEM_NAME__ AS table_catalog_id,
       CAST(__ITEM_NAME__ AS VARCHAR) AS table_catalog_name,
       CAST(NULL AS VARCHAR) AS pipe_catalog_name,
       CAST(NULL AS VARCHAR) AS pipe_schema_name,
       CAST(NULL AS VARCHAR) AS pipe_name,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS pipe_received_time,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS first_commit_time,
       CAST(NULL AS NUMBER(38,0)) AS bytes_billed
FROM __ITEM__.INFORMATION_SCHEMA.LOAD_HISTORY
