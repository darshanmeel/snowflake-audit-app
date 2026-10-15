-- shim: ROLES
-- reads: SHOW ROLES
-- show: SHOW ROLES
-- needs: MANAGE GRANTS
-- note: account roles only (no database or instance roles); the name stands in for the role id
-- ROLES rebuilt from SHOW ROLES: each column taken by name, mapped, or NULL where the source has none.
SELECT "name" AS role_id,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created_on,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted_on,
       CAST("name" AS VARCHAR) AS name,
       CAST("comment" AS VARCHAR) AS comment,
       CAST("owner" AS VARCHAR) AS owner,
       CAST('ROLE' AS VARCHAR) AS role_type,
       CAST(NULL AS VARCHAR) AS role_database_name,
       CAST(NULL AS NUMBER(38,0)) AS role_instance_id,
       CAST(NULL AS VARCHAR) AS owner_role_type,
       CAST(TRY_TO_BOOLEAN("is_from_organization_user_group"::STRING) AS BOOLEAN) AS is_from_organization_user_group
FROM __SHOW__
