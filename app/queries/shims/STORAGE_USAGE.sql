-- shim: STORAGE_USAGE
-- reads: INFORMATION_SCHEMA.DATABASE_STORAGE_USAGE_HISTORY, STAGE_STORAGE_USAGE_HISTORY (table functions)
-- needs: MONITOR USAGE
-- note: storage for 6 months at most; no hybrid table or archive storage
-- STORAGE_USAGE rebuilt from the database and stage storage table functions, one row per day.
SELECT COALESCE(d.usage_date, s.usage_date) AS usage_date, d.storage_bytes, s.stage_bytes, d.failsafe_bytes,
       CAST(NULL AS NUMBER) AS hybrid_table_storage_bytes, CAST(NULL AS NUMBER) AS archive_storage_cool_bytes,
       CAST(NULL AS NUMBER) AS archive_storage_cold_bytes, CAST(NULL AS NUMBER) AS archive_storage_retrieval_temp_bytes
FROM (
  SELECT usage_date, SUM(average_database_bytes) AS storage_bytes, SUM(average_failsafe_bytes) AS failsafe_bytes
  FROM TABLE(__INFO_SCHEMA__.DATABASE_STORAGE_USAGE_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_DATE()))
  GROUP BY usage_date
) d
FULL OUTER JOIN (
  SELECT usage_date, average_stage_bytes AS stage_bytes
  FROM TABLE(__INFO_SCHEMA__.STAGE_STORAGE_USAGE_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_DATE()))
) s ON s.usage_date = d.usage_date
