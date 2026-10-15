-- shim: PASSWORD_POLICIES
-- reads: SHOW PASSWORD POLICIES
-- show: SHOW PASSWORD POLICIES IN ACCOUNT
-- needs: MANAGE GRANTS
-- note: live policies only; no settings (SHOW does not give them); the name stands in for ids
-- PASSWORD_POLICIES rebuilt from SHOW PASSWORD POLICIES: each column taken by name, mapped, or NULL where the source has none.
SELECT "database_name" || '.' || "schema_name" || '.' || "name" AS id,
       CAST("name" AS VARCHAR) AS name,
       "database_name" || '.' || "schema_name" AS schema_id,
       CAST("schema_name" AS VARCHAR) AS schema,
       "database_name" AS database_id,
       CAST("database_name" AS VARCHAR) AS database,
       CAST("owner" AS VARCHAR) AS owner,
       CAST("owner_role_type" AS VARCHAR) AS owner_role_type,
       CAST(NULL AS NUMBER(38,0)) AS password_min_length,
       CAST(NULL AS NUMBER(38,0)) AS password_max_length,
       CAST(NULL AS NUMBER(38,0)) AS password_min_upper_case_chars,
       CAST(NULL AS NUMBER(38,0)) AS password_min_lower_case_chars,
       CAST(NULL AS NUMBER(38,0)) AS password_min_numeric_chars,
       CAST(NULL AS NUMBER(38,0)) AS password_min_special_chars,
       CAST(NULL AS NUMBER(38,0)) AS password_min_age_days,
       CAST(NULL AS NUMBER(38,0)) AS password_max_age_days,
       CAST(NULL AS NUMBER(38,0)) AS password_max_retries,
       CAST(NULL AS NUMBER(38,0)) AS password_lockout_time_mins,
       CAST(NULL AS NUMBER(38,0)) AS password_history,
       CAST("comment" AS VARCHAR) AS comment,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted
FROM __SHOW__
