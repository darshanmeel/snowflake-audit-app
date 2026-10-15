-- shim: DATA_TRANSFER_HISTORY
-- reads: INFORMATION_SCHEMA.DATA_TRANSFER_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: data transfer for the last 14 days at most
SELECT start_time, end_time, source_cloud, source_region, target_cloud, target_region, bytes_transferred, transfer_type
FROM TABLE(__INFO_SCHEMA__.DATA_TRANSFER_HISTORY(DATE_RANGE_START => DATEADD(day, -14, CURRENT_DATE()), DATE_RANGE_END => CURRENT_TIMESTAMP()))
