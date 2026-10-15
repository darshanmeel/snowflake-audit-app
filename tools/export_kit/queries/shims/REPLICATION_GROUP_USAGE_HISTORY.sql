-- shim: REPLICATION_GROUP_USAGE_HISTORY
-- reads: INFORMATION_SCHEMA.REPLICATION_GROUP_USAGE_HISTORY (table function)
-- needs: MONITOR USAGE
-- note: replication credits for 6 months at most; the group name stands in for its id
-- REPLICATION_GROUP_USAGE_HISTORY rebuilt from INFORMATION_SCHEMA.REPLICATION_GROUP_USAGE_HISTORY (table function): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST(start_time AS TIMESTAMP_LTZ(9)) AS start_time,
       CAST(end_time AS TIMESTAMP_LTZ(9)) AS end_time,
       CAST(replication_group_name AS VARCHAR) AS replication_group_name,
       replication_group_name AS replication_group_id,
       CAST(credits_used AS NUMBER(38,9)) AS credits_used,
       CAST(bytes_transferred AS NUMBER(38,0)) AS bytes_transferred,
       CAST(changed_object_count AS NUMBER(38,0)) AS changed_object_count
FROM TABLE(__INFO_SCHEMA__.REPLICATION_GROUP_USAGE_HISTORY(DATE_RANGE_START => DATEADD(day, 1, DATEADD(month, -6, CURRENT_DATE())), DATE_RANGE_END => CURRENT_TIMESTAMP()))
