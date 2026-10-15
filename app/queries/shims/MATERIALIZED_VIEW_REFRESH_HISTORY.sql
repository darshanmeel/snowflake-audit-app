-- shim: MATERIALIZED_VIEW_REFRESH_HISTORY
-- reads: INFORMATION_SCHEMA.MATERIALIZED_VIEW_REFRESH_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: materialized view credits for 6 months at most; no database or schema names, and the view name stands in for its id
-- MATERIALIZED_VIEW_REFRESH_HISTORY rebuilt from INFORMATION_SCHEMA.MATERIALIZED_VIEW_REFRESH_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(start_time AS TIMESTAMP_LTZ(9)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       CAST(credits_used AS NUMBER(38,9)) AS credits_used,
       materialized_view_name AS table_id,
       CAST(materialized_view_name AS VARCHAR) AS table_name,
       CAST(NULL AS NUMBER(38,0)) AS schema_id,
       CAST(NULL AS VARCHAR) AS schema_name,
       CAST(NULL AS NUMBER(38,0)) AS database_id,
       CAST(NULL AS VARCHAR) AS database_name
FROM TABLE(__INFO_SCHEMA__.MATERIALIZED_VIEW_REFRESH_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
