-- shim: SESSION_POLICIES
-- reads: SHOW SESSION POLICIES
-- show: SHOW SESSION POLICIES IN ACCOUNT
-- needs: MANAGE GRANTS
-- note: live policies only; no settings (SHOW does not give them); the name stands in for ids
-- SESSION_POLICIES rebuilt from SHOW SESSION POLICIES: each column taken by name, mapped, or NULL where the source has none.
SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS id,
       CAST("name" AS VARCHAR) AS name,
       "database_name" || '.' || "schema_name" AS schema_id,
       CAST("schema_name" AS VARCHAR) AS schema,
       "database_name" AS database_id,
       CAST("database_name" AS VARCHAR) AS database,
       CAST("owner" AS VARCHAR) AS owner,
       CAST("owner_role_type" AS VARCHAR) AS owner_role_type,
       CAST(NULL AS NUMBER(38,0)) AS session_idle_timeout_mins,
       CAST(NULL AS NUMBER(38,0)) AS session_ui_idle_timeout_mins,
       CAST(NULL AS NUMBER(38,0)) AS session_max_lifespan_mins,
       CAST(NULL AS NUMBER(38,0)) AS session_ui_max_lifespan_mins,
       CAST("comment" AS VARCHAR) AS comment,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted
FROM __SHOW__
