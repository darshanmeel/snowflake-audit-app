-- shim: GRANTS_TO_USERS
-- reads: SHOW GRANTS OF ROLE (per role)
-- each: role
-- show: SHOW GRANTS OF ROLE __ITEM__
-- needs: MANAGE GRANTS
-- note: current role grants to users
-- columns: CREATED_ON TIMESTAMP_LTZ(6), DELETED_ON TIMESTAMP_LTZ(6), ROLE VARCHAR, GRANTED_TO VARCHAR, GRANTEE_NAME VARCHAR, GRANTED_BY VARCHAR
-- GRANTS_TO_USERS rebuilt from SHOW GRANTS OF ROLE (per role): each column taken by name, mapped, or NULL where the source has none.
SELECT CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created_on,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted_on,
       CAST("role" AS VARCHAR) AS role,
       CAST("granted_to" AS VARCHAR) AS granted_to,
       CAST("grantee_name" AS VARCHAR) AS grantee_name,
       CAST("granted_by" AS VARCHAR) AS granted_by
FROM __SHOW__
WHERE "granted_to" = 'USER'
