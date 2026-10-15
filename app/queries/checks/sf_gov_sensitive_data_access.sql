-- query_id: sf_gov_sensitive_data_access
-- title: Who read sensitive columns
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :crit_users (default 25) users: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user x role x table whose sensitive-tagged columns (see
--   sf_gov_sensitive_columns_unprotected) were read in the window, resolved to base tables so reads
--   through views count. unmasked_columns lists the columns read that no masking policy covers.
-- healthy: status = OK when every sensitive column read is covered by a masking policy.
-- investigate_if: WARN when unmasked sensitive columns were read; CRITICAL when they were read under
--   ACCOUNTADMIN, SECURITYADMIN, SYSADMIN or ORGADMIN (admin roles should not be used to query data) or
--   by :crit_users+ distinct users.
-- actions: 1) check that each user and role needs the data; revoke the role otherwise (free); 2) mask
--   the unmasked columns, allowing clear text only to named roles (config); 3) stop querying data under
--   admin roles (free)
-- next: none
-- caveats: ACCESS_HISTORY needs Enterprise edition and lags up to 3 hours; only tagged columns are
--   seen, and a read of a masked column may still have returned clear text to a role the policy allows.
WITH __INCLUDE_sf_gov_sensitive_columns__,
reads AS (
  SELECT ah.query_id, ah.user_name, ah.query_start_time,
         UPPER(obj.value:"objectName"::VARCHAR) AS object_fqn,
         UPPER(col.value:"columnName"::VARCHAR) AS column_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ah.base_objects_accessed) obj,
       LATERAL FLATTEN(input => obj.value:"columns") col
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
hits AS (
  SELECT r.*, s.database_name || '.' || s.schema_name || '.' || s.table_name AS table_fqn,
         s.masking_policies IS NOT NULL AS is_masked, s.privacy_category
  FROM reads r
  JOIN sf_gov_sensitive_columns s
    ON REPLACE(r.object_fqn, '"', '') = s.database_name || '.' || s.schema_name || '.' || s.table_name
   AND r.column_name = s.column_name
),
roles AS (
  SELECT query_id, role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
g AS (
  SELECT h.user_name, q.role_name, h.table_fqn,
         COUNT(DISTINCT h.query_id) AS queries,
         COUNT(DISTINCT h.column_name) AS sensitive_columns_read,
         LISTAGG(DISTINCT IFF(h.is_masked, NULL, h.column_name), ', ') AS unmasked_columns,
         LISTAGG(DISTINCT h.privacy_category, ', ') AS privacy_categories,
         MIN(h.query_start_time) AS first_read, MAX(h.query_start_time) AS last_read
  FROM hits h
  LEFT JOIN roles q ON q.query_id = h.query_id
  GROUP BY h.user_name, q.role_name, h.table_fqn
),
f AS (
  SELECT g.*, NULLIF(unmasked_columns, '') IS NOT NULL AS read_unmasked,
         COUNT(DISTINCT IFF(NULLIF(unmasked_columns, '') IS NOT NULL, user_name, NULL))
           OVER (PARTITION BY table_fqn) AS table_users_unmasked
  FROM g
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, role_name, table_fqn, queries,
       sensitive_columns_read, NULLIF(unmasked_columns, '') AS unmasked_columns, privacy_categories,
       table_users_unmasked, first_read, last_read,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         queries || ' queries read ' || sensitive_columns_read || ' sensitive columns',
         IFF(read_unmasked, 'unmasked: ' || unmasked_columns, NULL),
         IFF(read_unmasked AND role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'ORGADMIN'),
             'read under ' || role_name, NULL),
         IFF(read_unmasked AND table_users_unmasked >= :crit_users,
             table_users_unmasked || ' users read it unmasked', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN NOT read_unmasked THEN 'OK'
         WHEN role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'ORGADMIN')
              OR table_users_unmasked >= :crit_users THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM f
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, queries DESC
