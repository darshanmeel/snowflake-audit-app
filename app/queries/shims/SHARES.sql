-- shim: SHARES
-- reads: SHOW SHARES
-- show: SHOW SHARES
-- needs: MANAGE GRANTS
-- note: live outbound shares only
-- SHARES rebuilt from SHOW SHARES: each column taken by name, mapped, or NULL where the source has none.
SELECT CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created_on,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS modified_on,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted_on,
       CAST("name" AS VARCHAR) AS name,
       CAST("owner" AS VARCHAR) AS owner,
       CAST("comment" AS VARCHAR) AS comment,
       CAST("database_name" AS VARCHAR) AS database_name,
       CAST(TRY_TO_BOOLEAN("secure_objects_only"::STRING) AS BOOLEAN) AS secure_objects_only,
       CAST("to" AS VARCHAR) AS target_accounts,
       CAST("listing_global_name" AS VARCHAR) AS listing_global_name
FROM __SHOW__
WHERE "kind" = 'OUTBOUND'
