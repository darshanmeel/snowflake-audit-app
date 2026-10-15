-- shim: PROJECTION_POLICIES
-- reads: SHOW PROJECTION POLICIES
-- show: SHOW PROJECTION POLICIES IN ACCOUNT
-- needs: MANAGE GRANTS
-- note: live policies only; no signature or body; the name stands in for ids
-- PROJECTION_POLICIES rebuilt from SHOW PROJECTION POLICIES: each column taken by name, mapped, or NULL where the source has none.
SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS policy_id,
       CAST("name" AS VARCHAR) AS policy_name,
       "database_name" || '.' || "schema_name" AS policy_schema_id,
       CAST("schema_name" AS VARCHAR) AS policy_schema,
       "database_name" AS policy_catalog_id,
       CAST("database_name" AS VARCHAR) AS policy_catalog,
       CAST("owner" AS VARCHAR) AS policy_owner,
       CAST(NULL AS VARCHAR) AS policy_signature,
       CAST(NULL AS VARCHAR) AS policy_return_type,
       CAST(CAST(NULL AS VARCHAR) AS VARCHAR) AS policy_body,
       TO_VARIANT("comment") AS policy_comment,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST("owner_role_type" AS VARCHAR) AS owner_role_type
FROM __SHOW__
