-- shim: SECRETS
-- reads: SHOW SECRETS
-- show: SHOW SECRETS IN ACCOUNT
-- needs: MANAGE GRANTS
-- note: live secrets only; no token expiry dates; the name stands in for ids
-- SECRETS rebuilt from SHOW SECRETS: each column taken by name, mapped, or NULL where the source has none.
SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS id,
       CAST("name" AS VARCHAR) AS name,
       "database_name" || '.' || "schema_name" AS schema_id,
       CAST("schema_name" AS VARCHAR) AS schema,
       "database_name" AS database_id,
       CAST("database_name" AS VARCHAR) AS database,
       CAST("owner" AS VARCHAR) AS owner,
       CAST("owner_role_type" AS VARCHAR) AS owner_role_type,
       CAST("secret_type" AS VARCHAR) AS secret_type,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS oauth_access_token_expiry_timestamp,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS oauth_refresh_token_expiry_timestamp,
       CAST("oauth_scopes" AS VARCHAR) AS oauth_scopes,
       CAST(NULL AS VARCHAR) AS api_authentication_integration_name,
       TO_VARIANT("comment") AS comment,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created_on,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS last_altered_on,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted_on,
       CAST(NULL AS VARCHAR) AS algorithm,
       CAST(NULL AS VARIANT) AS key_length
FROM __SHOW__
