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
WITH -- Columns marked sensitive by a tag (Snowflake's SEMANTIC_CATEGORY / PRIVACY_CATEGORY system tags, or a
-- custom tag whose name says PII, sensitive, confidential, PHI, PCI, GDPR, personal or restricted), with
-- whether a masking policy covers them directly or through a tag on the column, table, schema or database.
sf_gov_tag_refs AS (
  SELECT UPPER(tag_database) AS tag_database, UPPER(tag_schema) AS tag_schema, UPPER(tag_name) AS tag_name,
         tag_value, UPPER(domain) AS domain, UPPER(object_database) AS object_database,
         UPPER(object_schema) AS object_schema, UPPER(object_name) AS object_name, UPPER(column_name) AS column_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL
),
-- Which tags mean "sensitive": Snowflake's classification system tags (any value but INSENSITIVE) or a custom
-- tag whose name says so (short acronyms as whole words only, so GEOGRAPHIC is not PHI) with a value that
-- is not a "no" (FALSE, NO, NONE, PUBLIC, INSENSITIVE ...).
sf_gov_sensitive_tagged AS (
  SELECT object_database AS database_name, object_schema AS schema_name, object_name AS table_name, column_name,
         MAX(IFF(tag_database = 'SNOWFLAKE' AND tag_name = 'PRIVACY_CATEGORY', UPPER(tag_value), NULL)) AS privacy_category,
         MAX(IFF(tag_database = 'SNOWFLAKE' AND tag_name = 'SEMANTIC_CATEGORY', UPPER(tag_value), NULL)) AS semantic_category,
         LISTAGG(DISTINCT IFF(tag_database = 'SNOWFLAKE', NULL, tag_database || '.' || tag_schema || '.' || tag_name
                 || COALESCE('=' || tag_value, '')), ', ') AS custom_tags,
         COALESCE(BOOLOR_AGG(tag_database <> 'SNOWFLAKE'
                  AND REGEXP_LIKE(tag_name, '(^|.*[^A-Z0-9])(PII|PHI|PCI)([^A-Z0-9].*|$)')), FALSE) AS has_pii_tag
  FROM sf_gov_tag_refs
  WHERE domain = 'COLUMN'
    AND ((tag_database = 'SNOWFLAKE' AND tag_schema = 'CORE' AND tag_name IN ('PRIVACY_CATEGORY', 'SEMANTIC_CATEGORY')
          AND UPPER(COALESCE(tag_value, '')) <> 'INSENSITIVE')
         OR (tag_database <> 'SNOWFLAKE'
             AND (REGEXP_LIKE(tag_name, '(^|.*[^A-Z0-9])(PII|PHI|PCI|GDPR)([^A-Z0-9].*|$)')
                  OR (REGEXP_LIKE(tag_name, '.*(SENSITIV|CONFIDENTIAL|PERSONAL|RESTRICTED).*')
                      AND NOT REGEXP_LIKE(tag_name, '.*(INSENSITIV|NON.?SENSITIV|NOT.?SENSITIV).*')))
             AND UPPER(COALESCE(tag_value, '')) NOT IN
                 ('FALSE', 'NO', 'N', 'NONE', 'PUBLIC', 'INSENSITIVE', 'NON_SENSITIVE', 'NON-SENSITIVE', 'NOT_SENSITIVE', '0')))
  GROUP BY 1, 2, 3, 4
),
sf_gov_policy_refs AS (
  SELECT policy_kind, UPPER(policy_db || '.' || policy_schema || '.' || policy_name) AS policy_fqn,
         UPPER(ref_database_name) AS ref_database_name, UPPER(ref_schema_name) AS ref_schema_name,
         UPPER(ref_entity_name) AS ref_entity_name, UPPER(ref_entity_domain) AS ref_entity_domain,
         UPPER(ref_column_name) AS ref_column_name, UPPER(tag_database) AS tag_database,
         UPPER(tag_schema) AS tag_schema, UPPER(tag_name) AS tag_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  -- A policy attached but not ACTIVE (for example two masks on one column) does not protect anything.
  WHERE UPPER(policy_status) = 'ACTIVE'
),
-- Tags that carry a masking policy (tag-based masking), as reported either way round.
sf_gov_masking_tags AS (
  SELECT DISTINCT tag_database, tag_schema, tag_name, policy_fqn
  FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND tag_name IS NOT NULL
  UNION
  SELECT DISTINCT ref_database_name, ref_schema_name, ref_entity_name, policy_fqn
  FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND ref_entity_domain = 'TAG'
),
sf_gov_tag_masked AS (
  SELECT r.object_database, r.object_schema, r.object_name, r.column_name, r.domain,
         LISTAGG(DISTINCT m.policy_fqn, ', ') AS policies
  FROM sf_gov_tag_refs r
  JOIN sf_gov_masking_tags m
    ON m.tag_database = r.tag_database AND m.tag_schema = r.tag_schema AND m.tag_name = r.tag_name
  GROUP BY 1, 2, 3, 4, 5
),
sf_gov_sensitive_columns AS (
  SELECT s.*,
         COALESCE(d.policies, tc.policies, tt.policies, ts.policies, tdb.policies) AS masking_policies,
         CASE WHEN d.policies IS NOT NULL THEN 'column policy'
              WHEN tc.policies IS NOT NULL THEN 'tag on column'
              WHEN tt.policies IS NOT NULL THEN 'tag on table'
              WHEN ts.policies IS NOT NULL THEN 'tag on schema'
              WHEN tdb.policies IS NOT NULL THEN 'tag on database' END AS masked_via,
         rap.policies AS row_access_policies
  FROM sf_gov_sensitive_tagged s
  LEFT JOIN (
    SELECT ref_database_name, ref_schema_name, ref_entity_name, ref_column_name, LISTAGG(DISTINCT policy_fqn, ', ') AS policies
    FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND ref_column_name IS NOT NULL
    GROUP BY 1, 2, 3, 4
  ) d ON d.ref_database_name = s.database_name AND d.ref_schema_name = s.schema_name
     AND d.ref_entity_name = s.table_name AND d.ref_column_name = s.column_name
  LEFT JOIN sf_gov_tag_masked tc ON tc.domain = 'COLUMN' AND tc.object_database = s.database_name
     AND tc.object_schema = s.schema_name AND tc.object_name = s.table_name AND tc.column_name = s.column_name
  LEFT JOIN sf_gov_tag_masked tt ON tt.domain = 'TABLE' AND tt.object_database = s.database_name
     AND tt.object_schema = s.schema_name AND tt.object_name = s.table_name
  LEFT JOIN sf_gov_tag_masked ts ON ts.domain = 'SCHEMA' AND ts.object_database = s.database_name
     AND ts.object_name = s.schema_name
  LEFT JOIN sf_gov_tag_masked tdb ON tdb.domain = 'DATABASE' AND tdb.object_name = s.database_name
  LEFT JOIN (
    SELECT ref_database_name, ref_schema_name, ref_entity_name, LISTAGG(DISTINCT policy_fqn, ', ') AS policies
    FROM sf_gov_policy_refs WHERE policy_kind = 'ROW_ACCESS_POLICY'
    GROUP BY 1, 2, 3
  ) rap ON rap.ref_database_name = s.database_name AND rap.ref_schema_name = s.schema_name
     AND rap.ref_entity_name = s.table_name
),
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
