-- shim: REPLICATION_GROUP_REFRESH_HISTORY
-- reads: INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY_ALL (table function)
-- note: refreshes for the last 14 days only, for the groups this role holds a privilege on; the group name stands in for its id
-- REPLICATION_GROUP_REFRESH_HISTORY rebuilt from INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY_ALL (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(group_name AS VARCHAR) AS replication_group_name,
       group_name AS replication_group_id,
       CAST(phase_name AS VARCHAR) AS phase_name,
       CAST(start_time AS TIMESTAMP_LTZ(3)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(3)) AS end_time,
       CAST(job_uuid AS VARCHAR) AS job_uuid,
       total_bytes AS total_bytes,
       object_count AS object_count,
       CAST(primary_snapshot_timestamp AS TIMESTAMP_LTZ(9)) AS primary_snapshot_timestamp,
       error AS error
FROM TABLE(__INFO_SCHEMA__.REPLICATION_GROUP_REFRESH_HISTORY_ALL(DATE_RANGE_START => DATEADD(minute, -20100, CURRENT_TIMESTAMP()), DATE_RANGE_END => CURRENT_TIMESTAMP()))
