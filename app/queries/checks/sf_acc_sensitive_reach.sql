-- query_id: sf_acc_sensitive_reach
-- title: Who can read or change each table with sensitive columns
-- domain: governance_access   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS,
--   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES, SNOWFLAKE.ACCOUNT_USAGE.ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition for tags and policies
-- params: :dormant_days (default 90) dormant days: a person with no sign-in for this long counts as
--   dormant
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table or view with sensitive-tagged columns. readers counts users who can
--   read it through any role (SELECT or ownership, PUBLIC included); dormant_readers are people with no
--   sign-in for :dormant_days days, disabled_readers are disabled users who still hold the path,
--   people_writers are people who can change it.
-- healthy: status = OK when only active users can read it and only service users can change it.
-- investigate_if: WARN when dormant or disabled users can read it, or people can change it; CRITICAL
--   when dormant or disabled users can read a sensitive column that has no masking policy.
-- actions: 1) revoke the roles of dormant and disabled users (free); 2) mask the sensitive columns
--   (config); 3) move write access to a service user that loads the table (free)
-- next: sf_gov_sensitive_data_access
-- caveats: "can" means a grant path exists; USAGE on the database and schema is not checked.
--   Who did read it is in sf_gov_sensitive_data_access. Lags up to 2
--   hours.
WITH __INCLUDE_sf_gov_sensitive_columns__,
__INCLUDE_sf_sec_users__,
__INCLUDE_sf_sec_user_roles__,
tables_ AS (
  SELECT database_name, schema_name, table_name, COUNT(*) AS sensitive_columns,
         COUNT_IF(masking_policies IS NOT NULL) AS masked_columns,
         MAX(row_access_policies) IS NOT NULL AS has_row_policy,
         LISTAGG(DISTINCT column_name, ', ') WITHIN GROUP (ORDER BY column_name) AS column_list
  FROM sf_gov_sensitive_columns
  GROUP BY 1, 2, 3
),
obj AS (
  SELECT IFF(granted_to = 'DATABASE_ROLE' AND NOT CONTAINS(grantee_name, '.'), table_catalog || '.' || grantee_name,
             grantee_name) AS role_name, UPPER(table_catalog) AS database_name, UPPER(table_schema) AS schema_name,
         UPPER(name) AS table_name,
         BOOLOR_AGG(privilege IN ('SELECT', 'OWNERSHIP')) AS can_read,
         BOOLOR_AGG(privilege IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'OWNERSHIP')) AS can_write
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on IS NULL AND granted_to IN ('ROLE', 'ACCOUNT ROLE', 'DATABASE_ROLE')
    AND granted_on IN ('TABLE', 'VIEW', 'MATERIALIZED_VIEW', 'MATERIALIZED VIEW', 'DYNAMIC_TABLE',
                       'EXTERNAL_TABLE', 'ICEBERG_TABLE', 'EVENT_TABLE')
  GROUP BY 1, 2, 3, 4
),
-- Every user holds PUBLIC without a grant row, and every role granted to PUBLIC with it.
user_roles AS (
  SELECT user_name, role_name FROM sf_sec_user_roles
  UNION
  SELECT u.user_name, r.role_name FROM sf_sec_users u JOIN sf_sec_role_reach r ON r.top_role = 'PUBLIC'
  UNION
  SELECT user_name, 'PUBLIC' FROM sf_sec_users
),
access_ AS (
  SELECT ur.user_name, o.database_name, o.schema_name, o.table_name,
         BOOLOR_AGG(o.can_read) AS can_read, BOOLOR_AGG(o.can_write) AS can_write
  FROM user_roles ur
  JOIN obj o ON o.role_name = ur.role_name
  GROUP BY 1, 2, 3, 4
),
users_ AS (
  SELECT user_name, is_disabled, user_type = 'PERSON' AS is_person,
         user_type = 'PERSON' AND NOT is_disabled
           AND COALESCE(DATEDIFF(day, last_success_login, __AS_OF_DATE__), DATEDIFF(day, created_on, __AS_OF_DATE__))
               >= :dormant_days AS is_dormant
  FROM sf_sec_users
),
per AS (
  SELECT t.*,
         COUNT(DISTINCT IFF(a.can_read, a.user_name, NULL)) AS readers,
         COUNT(DISTINCT IFF(a.can_read AND u.is_person AND NOT u.is_disabled, a.user_name, NULL)) AS people_readers,
         COUNT(DISTINCT IFF(a.can_read AND u.is_dormant, a.user_name, NULL)) AS dormant_readers,
         COUNT(DISTINCT IFF(a.can_read AND u.is_disabled, a.user_name, NULL)) AS disabled_readers,
         COUNT(DISTINCT IFF(a.can_write AND u.is_person AND NOT u.is_disabled, a.user_name, NULL)) AS people_writers,
         LISTAGG(DISTINCT IFF(a.can_read AND (u.is_dormant OR u.is_disabled), a.user_name, NULL), ', ')
           WITHIN GROUP (ORDER BY IFF(a.can_read AND (u.is_dormant OR u.is_disabled), a.user_name, NULL)) AS idle_users,
         LISTAGG(DISTINCT IFF(a.can_write AND u.is_person AND NOT u.is_disabled, a.user_name, NULL), ', ')
           WITHIN GROUP (ORDER BY IFF(a.can_write AND u.is_person AND NOT u.is_disabled, a.user_name, NULL)) AS writing_users
  FROM tables_ t
  LEFT JOIN access_ a ON a.database_name = t.database_name AND a.schema_name = t.schema_name AND a.table_name = t.table_name
  LEFT JOIN users_ u ON u.user_name = a.user_name
  GROUP BY t.database_name, t.schema_name, t.table_name, t.sensitive_columns, t.masked_columns, t.has_row_policy,
           t.column_list
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name, table_name,
       database_name || '.' || schema_name || '.' || table_name AS table_fqn,
       sensitive_columns, masked_columns, has_row_policy, column_list, readers, people_readers, dormant_readers,
       disabled_readers, people_writers, NULLIF(idle_users, '') AS idle_users,
       NULLIF(writing_users, '') AS writing_users,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(dormant_readers > 0, 'dormant people who can read it: ' || dormant_readers, NULL),
         IFF(disabled_readers > 0, 'disabled users with a path to it: ' || disabled_readers, NULL),
         IFF(people_writers > 0, 'people who can change it: ' || people_writers, NULL),
         IFF(masked_columns < sensitive_columns, 'unmasked sensitive columns: ' || (sensitive_columns - masked_columns), NULL)),
         '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN dormant_readers + disabled_readers > 0 AND masked_columns < sensitive_columns THEN 'CRITICAL'
         WHEN dormant_readers + disabled_readers > 0 OR people_writers > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM per
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, readers DESC, table_fqn
