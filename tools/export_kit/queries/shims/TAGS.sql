-- shim: TAGS
-- reads: SHOW TAGS
-- show: SHOW TAGS IN ACCOUNT
-- needs: MANAGE GRANTS
-- note: live tags only; the name stands in for ids
-- TAGS rebuilt from SHOW TAGS: each column taken by name, mapped, or NULL where the source has none.
SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS tag_id,
       CAST("name" AS VARCHAR) AS tag_name,
       "database_name" || '.' || "schema_name" AS tag_schema_id,
       CAST("schema_name" AS VARCHAR) AS tag_schema,
       "database_name" AS tag_database_id,
       CAST("database_name" AS VARCHAR) AS tag_database,
       CAST("owner" AS VARCHAR) AS tag_owner,
       TO_VARIANT("comment") AS tag_comment,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       TRY_PARSE_JSON(TO_VARCHAR("allowed_values")) AS allowed_values,
       CAST("owner_role_type" AS VARCHAR) AS owner_role_type,
       CAST("propagate" AS VARCHAR) AS propagate,
       CAST("on_conflict" AS VARCHAR) AS on_conflict,
       CAST(TRY_TO_BOOLEAN("multi_value"::STRING) AS BOOLEAN) AS multi_value
FROM __SHOW__
