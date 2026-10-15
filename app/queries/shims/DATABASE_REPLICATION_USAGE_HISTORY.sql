-- shim: DATABASE_REPLICATION_USAGE_HISTORY
-- reads: INFORMATION_SCHEMA.DATABASE_REPLICATION_USAGE_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: database replication credits for the last 14 days only; the database name stands in for its id
-- DATABASE_REPLICATION_USAGE_HISTORY rebuilt from INFORMATION_SCHEMA.DATABASE_REPLICATION_USAGE_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(start_time AS TIMESTAMP_LTZ(9)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       CAST(database_name AS VARCHAR) AS database_name,
       database_name AS database_id,
       CAST(credits_used AS NUMBER(38,9)) AS credits_used,
       CAST(bytes_transferred AS NUMBER(38,0)) AS bytes_transferred
FROM TABLE(__INFO_SCHEMA__.DATABASE_REPLICATION_USAGE_HISTORY(DATE_RANGE_START => __SHIM_14_DAYS__, DATE_RANGE_END => CURRENT_TIMESTAMP()))
