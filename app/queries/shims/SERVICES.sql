-- shim: SERVICES
-- reads: SHOW SERVICES
-- show: SHOW SERVICES IN ACCOUNT
-- needs: MANAGE GRANTS
-- note: live services only; the name stands in for ids
-- SERVICES rebuilt from SHOW SERVICES: each column taken by name, mapped, or NULL where the source has none.
SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS service_id,
       CAST("name" AS VARCHAR) AS service_name,
       "database_name" || '.' || "schema_name" AS service_schema_id,
       CAST("schema_name" AS VARCHAR) AS service_schema,
       "database_name" AS service_catalog_id,
       CAST("database_name" AS VARCHAR) AS service_catalog,
       CAST("owner" AS VARCHAR) AS service_owner,
       CAST("owner_role_type" AS VARCHAR) AS service_owner_role_type,
       "compute_pool" AS compute_pool_id,
       CAST("compute_pool" AS VARCHAR) AS compute_pool_name,
       CAST("dns_name" AS VARCHAR) AS dns_name,
       CAST("min_ready_instances" AS NUMBER(38,0)) AS min_ready_instances,
       CAST("min_instances" AS NUMBER(38,0)) AS min_instances,
       CAST("max_instances" AS NUMBER(38,0)) AS max_instances,
       CAST(TRY_TO_BOOLEAN("auto_resume"::STRING) AS BOOLEAN) AS auto_resume,
       CAST("comment" AS VARCHAR) AS comment,
       CAST("query_warehouse" AS VARCHAR) AS query_warehouse,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created,
       CAST("updated_on" AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST("resumed_on" AS TIMESTAMP_LTZ(6)) AS last_resumed,
       CAST("suspended_on" AS TIMESTAMP_LTZ(6)) AS last_suspended,
       CAST("auto_suspend_secs" AS NUMBER(38,0)) AS auto_suspend_secs,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(TRY_TO_BOOLEAN("is_job"::STRING) AS BOOLEAN) AS is_job,
       CAST(TRY_TO_BOOLEAN("is_async_job"::STRING) AS BOOLEAN) AS is_async_job
FROM __SHOW__
