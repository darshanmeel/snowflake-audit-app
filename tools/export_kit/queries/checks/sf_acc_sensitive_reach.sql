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
-- caveats: "can" means a grant path exists; USAGE on the database and schema is not checked, and
--   database roles are not followed. Who did read it is in sf_gov_sensitive_data_access. Lags up to 2
--   hours.
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
-- Live users with the auth flags normalised: DISABLED and EXT_AUTHN_DUO can come back as VARIANT
-- text, and a NULL TYPE behaves as PERSON.
sf_sec_users AS (
  SELECT TO_VARCHAR(user_id) AS user_id, name AS user_name, email, created_on,
         COALESCE(UPPER(type), 'PERSON') AS user_type,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE) AS is_disabled,
         COALESCE(has_password, FALSE) AS has_password,
         COALESCE(has_mfa, FALSE) AS has_mfa,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(ext_authn_duo)), FALSE) AS has_duo,
         COALESCE(has_rsa_public_key, FALSE) AS has_rsa_key,
         UPPER(default_role) AS default_role, UPPER(default_secondary_role) AS default_secondary_role,
         last_success_login, password_last_set_time, locked_until_time, owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  -- Snowflake-managed users (SNOWFLAKE, WORKSHEETS_APP_USER) are not the customer's to change.
  WHERE deleted_on IS NULL AND COALESCE(UPPER(type), '') <> 'SNOWFLAKE_SERVICE'
    AND UPPER(name) NOT IN ('SNOWFLAKE', 'WORKSHEETS_APP_USER')
),
-- Role hierarchy from live role-to-role grants: every role a role inherits (itself at depth 0), and
-- every role a user can use through a direct grant. A child role is NAME, its parent GRANTEE_NAME.
sf_sec_role_reach AS (
  SELECT name AS top_role, name AS role_name, 0 AS depth, CAST(name AS VARCHAR) AS path
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES
  WHERE deleted_on IS NULL
  UNION ALL
  SELECT r.top_role, g.name, r.depth + 1, r.path || ' > ' || g.name
  FROM sf_sec_role_reach r
  JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES g
    ON g.grantee_name = r.role_name AND g.granted_on = 'ROLE' AND g.granted_to IN ('ROLE', 'ACCOUNT ROLE')
   AND g.privilege = 'USAGE' AND g.deleted_on IS NULL
  -- Snowflake forbids cycles; the cap only guards against a malformed history.
  WHERE r.depth < 20
),
sf_sec_user_roles AS (
  SELECT gu.grantee_name AS user_name, gu.role AS granted_role, r.role_name, r.depth, r.path
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS gu
  JOIN sf_sec_role_reach r ON r.top_role = gu.role
  WHERE gu.deleted_on IS NULL
),
tables_ AS (
  SELECT database_name, schema_name, table_name, COUNT(*) AS sensitive_columns,
         COUNT_IF(masking_policies IS NOT NULL) AS masked_columns,
         MAX(row_access_policies) IS NOT NULL AS has_row_policy,
         LISTAGG(DISTINCT column_name, ', ') WITHIN GROUP (ORDER BY column_name) AS column_list
  FROM sf_gov_sensitive_columns
  GROUP BY 1, 2, 3
),
obj AS (
  SELECT grantee_name AS role_name, UPPER(table_catalog) AS database_name, UPPER(table_schema) AS schema_name,
         UPPER(name) AS table_name,
         BOOLOR_AGG(privilege IN ('SELECT', 'OWNERSHIP')) AS can_read,
         BOOLOR_AGG(privilege IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'OWNERSHIP')) AS can_write
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
  WHERE deleted_on IS NULL AND granted_to IN ('ROLE', 'ACCOUNT ROLE')
    AND granted_on IN ('TABLE', 'VIEW', 'MATERIALIZED_VIEW', 'MATERIALIZED VIEW', 'DYNAMIC_TABLE',
                       'EXTERNAL_TABLE', 'ICEBERG_TABLE', 'EVENT_TABLE')
  GROUP BY 1, 2, 3, 4
),
-- Every user holds PUBLIC without a grant row.
user_roles AS (
  SELECT user_name, role_name FROM sf_sec_user_roles
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
           WITHIN GROUP (ORDER BY IFF(a.can_read AND (u.is_dormant OR u.is_disabled), a.user_name, NULL)) AS idle_reader_list,
         LISTAGG(DISTINCT IFF(a.can_write AND u.is_person AND NOT u.is_disabled, a.user_name, NULL), ', ')
           WITHIN GROUP (ORDER BY IFF(a.can_write AND u.is_person AND NOT u.is_disabled, a.user_name, NULL)) AS writer_list
  FROM tables_ t
  LEFT JOIN access_ a ON a.database_name = t.database_name AND a.schema_name = t.schema_name AND a.table_name = t.table_name
  LEFT JOIN users_ u ON u.user_name = a.user_name
  GROUP BY t.database_name, t.schema_name, t.table_name, t.sensitive_columns, t.masked_columns, t.has_row_policy,
           t.column_list
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, schema_name, table_name,
       database_name || '.' || schema_name || '.' || table_name AS table_fqn,
       sensitive_columns, masked_columns, has_row_policy, column_list, readers, people_readers, dormant_readers,
       disabled_readers, people_writers, NULLIF(idle_reader_list, '') AS idle_reader_list,
       NULLIF(writer_list, '') AS writer_list,
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
