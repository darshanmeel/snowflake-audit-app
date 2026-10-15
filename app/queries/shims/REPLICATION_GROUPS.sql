-- shim: REPLICATION_GROUPS
-- reads: SHOW REPLICATION GROUPS
-- show: SHOW REPLICATION GROUPS
-- needs: MANAGE GRANTS
-- note: live groups in this account only
-- REPLICATION_GROUPS rebuilt from SHOW REPLICATION GROUPS: each column taken by name, mapped, or NULL where the source has none.
SELECT CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST("name" AS VARCHAR) AS name,
       CAST("type" AS VARCHAR) AS type,
       CAST("comment" AS VARCHAR) AS comment,
       CAST("object_types" AS VARCHAR) AS object_types,
       CAST("allowed_integration_types" AS VARCHAR) AS allowed_integration_types,
       CAST("replication_schedule" AS VARCHAR) AS replication_schedule,
       CAST("owner" AS VARCHAR) AS owner,
       CAST(TRY_TO_BOOLEAN("is_listing_auto_fulfillment_group"::STRING) AS BOOLEAN) AS is_listing_auto_fulfillment_group,
       CAST("error_integration" AS VARCHAR) AS error_integration,
       CAST(TRY_TO_BOOLEAN("is_optimized_refresh_enabled"::STRING) AS BOOLEAN) AS is_optimized_refresh_enabled
FROM __SHOW__
WHERE "account_locator" = CURRENT_ACCOUNT()
