-- shim: SEQUENCES
-- reads: INFORMATION_SCHEMA.SEQUENCES (view, per database)
-- each: database
-- note: the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- columns: SEQUENCE_ID VARCHAR, SEQUENCE_NAME VARCHAR, SEQUENCE_SCHEMA_ID VARCHAR, SEQUENCE_SCHEMA VARCHAR, SEQUENCE_CATALOG_ID VARCHAR, SEQUENCE_CATALOG VARCHAR, SEQUENCE_OWNER VARCHAR, DATA_TYPE VARCHAR, NUMERIC_PRECISION NUMBER(2,0), NUMERIC_PRECISION_RADIX NUMBER(2,0), NUMERIC_SCALE NUMBER(1,0), START_VALUE VARCHAR, MINIMUM_VALUE VARCHAR, MAXIMUM_VALUE VARCHAR, NEXT_VALUE VARCHAR, INCREMENT VARCHAR, CYCLE_OPTION VARCHAR, ORDERED VARCHAR, CREATED TIMESTAMP_LTZ(6), LAST_ALTERED TIMESTAMP_LTZ(6), DELETED TIMESTAMP_LTZ(6), COMMENT VARCHAR, OWNER_ROLE_TYPE VARCHAR
-- SEQUENCES rebuilt from INFORMATION_SCHEMA.SEQUENCES (view, per database): each column taken by name, mapped, or NULL where the source has none.
SELECT sequence_catalog || '.' || sequence_schema || '.' || sequence_name AS sequence_id,
       CAST(sequence_name AS VARCHAR) AS sequence_name,
       sequence_catalog || '.' || sequence_schema AS sequence_schema_id,
       CAST(sequence_schema AS VARCHAR) AS sequence_schema,
       sequence_catalog AS sequence_catalog_id,
       CAST(sequence_catalog AS VARCHAR) AS sequence_catalog,
       CAST(sequence_owner AS VARCHAR) AS sequence_owner,
       CAST(data_type AS VARCHAR) AS data_type,
       CAST(numeric_precision AS NUMBER(2,0)) AS numeric_precision,
       CAST(numeric_precision_radix AS NUMBER(2,0)) AS numeric_precision_radix,
       CAST(numeric_scale AS NUMBER(1,0)) AS numeric_scale,
       CAST(start_value AS VARCHAR) AS start_value,
       CAST(minimum_value AS VARCHAR) AS minimum_value,
       CAST(maximum_value AS VARCHAR) AS maximum_value,
       CAST(next_value AS VARCHAR) AS next_value,
       CAST("INCREMENT" AS VARCHAR) AS "INCREMENT",
       CAST(cycle_option AS VARCHAR) AS cycle_option,
       CAST(ordered AS VARCHAR) AS ordered,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(comment AS VARCHAR) AS comment,
       CAST(NULL AS VARCHAR) AS owner_role_type
FROM __ITEM__.INFORMATION_SCHEMA.SEQUENCES
