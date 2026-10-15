-- shim: DATABASE_STORAGE_USAGE_HISTORY
-- reads: INFORMATION_SCHEMA.DATABASE_STORAGE_USAGE_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: database storage for 6 months at most, live databases only; no hybrid or archive storage; the name stands in for the database id
-- DATABASE_STORAGE_USAGE_HISTORY rebuilt from INFORMATION_SCHEMA.DATABASE_STORAGE_USAGE_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(usage_date AS DATE) AS usage_date,
       database_name AS database_id,
       CAST(database_name AS VARCHAR) AS database_name,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(average_database_bytes AS FLOAT) AS average_database_bytes,
       CAST(average_failsafe_bytes AS FLOAT) AS average_failsafe_bytes,
       CAST(NULL AS FLOAT) AS average_hybrid_table_storage_bytes,
       CAST(NULL AS NUMBER(38,0)) AS average_archive_storage_cool_bytes,
       CAST(NULL AS NUMBER(38,0)) AS average_archive_storage_cold_bytes,
       CAST(NULL AS NUMBER(38,0)) AS average_archive_storage_cool_failsafe_bytes,
       CAST(NULL AS NUMBER(38,0)) AS average_archive_storage_cold_failsafe_bytes
FROM TABLE(__INFO_SCHEMA__.DATABASE_STORAGE_USAGE_HISTORY(DATE_RANGE_START => DATEADD(day, 1, DATEADD(month, -6, CURRENT_DATE())), DATE_RANGE_END => CURRENT_DATE()))
