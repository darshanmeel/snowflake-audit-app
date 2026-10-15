-- shim: STAGE_STORAGE_USAGE_HISTORY
-- reads: INFORMATION_SCHEMA.STAGE_STORAGE_USAGE_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: stage storage for 6 months at most
-- STAGE_STORAGE_USAGE_HISTORY rebuilt from INFORMATION_SCHEMA.STAGE_STORAGE_USAGE_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(usage_date AS DATE) AS usage_date,
       CAST(average_stage_bytes AS NUMBER(38,6)) AS average_stage_bytes
FROM TABLE(__INFO_SCHEMA__.STAGE_STORAGE_USAGE_HISTORY(DATE_RANGE_START => __SHIM_6_MONTHS__, DATE_RANGE_END => CURRENT_DATE()))
