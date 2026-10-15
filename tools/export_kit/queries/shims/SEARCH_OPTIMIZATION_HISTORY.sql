-- shim: SEARCH_OPTIMIZATION_HISTORY
-- reads: INFORMATION_SCHEMA.SEARCH_OPTIMIZATION_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: search optimization credits for 6 months at most; no database or schema names, and the table name stands in for its id
-- SEARCH_OPTIMIZATION_HISTORY rebuilt from INFORMATION_SCHEMA.SEARCH_OPTIMIZATION_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(start_time AS TIMESTAMP_LTZ(9)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       CAST(credits_used AS NUMBER(38,9)) AS credits_used,
       CAST(NULL AS NUMBER(38,0)) AS index_id,
       CAST(NULL AS VARCHAR) AS index_name,
       CAST(NULL AS NUMBER(38,0)) AS schema_id,
       CAST(NULL AS VARCHAR) AS schema_name,
       CAST(NULL AS NUMBER(38,0)) AS database_id,
       CAST(NULL AS VARCHAR) AS database_name,
       table_name AS base_table_id,
       CAST(table_name AS VARCHAR) AS base_table_name,
       CAST(NULL AS VARCHAR) AS index_type
FROM TABLE(__INFO_SCHEMA__.SEARCH_OPTIMIZATION_HISTORY(DATE_RANGE_START => DATEADD(day, 1, DATEADD(month, -6, CURRENT_DATE())), DATE_RANGE_END => CURRENT_TIMESTAMP()))
