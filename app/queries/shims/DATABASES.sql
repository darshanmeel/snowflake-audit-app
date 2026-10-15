-- shim: DATABASES
-- reads: INFORMATION_SCHEMA.DATABASES (view)
-- note: the databases this role can see; dropped databases are not listed; the name stands in for ids
-- DATABASES rebuilt from INFORMATION_SCHEMA.DATABASES (view): each column taken by name, mapped, or NULL where the source has none.
SELECT database_name AS database_id,
       CAST(database_name AS VARCHAR) AS database_name,
       CAST(database_owner AS VARCHAR) AS database_owner,
       CAST(is_transient AS VARCHAR) AS is_transient,
       CAST(comment AS VARCHAR) AS comment,
       CAST(created AS TIMESTAMP_LTZ(6)) AS created,
       CAST(last_altered AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(retention_time AS NUMBER(38,0)) AS retention_time,
       CAST(NULL AS VARCHAR) AS resource_group,
       CAST(type AS VARCHAR) AS type,
       CAST(owner_role_type AS VARCHAR) AS owner_role_type,
       CAST(NULL AS OBJECT) AS object_visibility,
       CAST(replicable_with_failover_groups AS VARCHAR) AS replicable_with_failover_groups,
       CAST(NULL AS VARCHAR) AS data_quality_monitoring_settings
FROM __INFO_SCHEMA__.DATABASES
