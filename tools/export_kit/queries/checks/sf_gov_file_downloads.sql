-- query_id: sf_gov_file_downloads
-- title: Files taken out: GET from stages and unloads, by user, stage and source table
-- domain: governance_access   tier: standard
-- entity: downloads = user_name, role_name, kind, stage_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition for the stage and source tables
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one day x user x role x client x kind (GET = files downloaded from a stage,
--   UNLOAD = COPY INTO a stage or location) x stage. queries counts the statements, rows_unloaded and
--   outbound_gb come from QUERY_HISTORY. source_tables lists the tables an unload read (up to 10, with
--   source_table_count exact), sensitive_tables those of them with a sensitive-tagged column. stage_name is
--   the stage (a user stage is named after its user); the external URL is not kept.
-- healthy: status = OK for service users and for downloads with no sensitive source table.
-- investigate_if: WARN when a person unloaded a table with sensitive columns, or downloaded files with
--   GET from a stage that such an unload wrote to in the window.
-- actions: 1) ask the user why the data left and where it went (free); 2) attach a data movement policy
--   to the sensitive tables to alert on or block unloads and downloads (config)
-- next: sf_sec_data_movement_violations
-- empty_if: role_cannot_see, no_activity
-- caveats: Snowflake does not log result downloads from Snowsight or what a driver (ODBC, JDBC, Excel,
--   BI tools) fetches; the reads behind them are in sf_use_access_log by client. A GET that succeeds means
--   Snowflake allowed the transfer, not that the file arrived. Stage and source tables need ACCESS_HISTORY
--   (Enterprise); without it they are NULL.
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
q AS (
  SELECT query_id, start_time, user_name, UPPER(role_name) AS role_name, session_id,
         IFF(query_type = 'GET_FILES', 'GET', 'UNLOAD') AS kind, COALESCE(rows_unloaded, 0) AS rows_unloaded,
         COALESCE(outbound_data_transfer_bytes, 0) AS outbound_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type IN ('GET_FILES', 'UNLOAD') AND execution_status = 'SUCCESS'
),
ah AS (
  SELECT query_id, base_objects_accessed, direct_objects_accessed, objects_modified
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
    AND query_id IN (SELECT query_id FROM q)
),
stages AS (
  SELECT a.query_id, MAX(UPPER(f.value:"objectName"::STRING)) AS stage_name
  FROM ah a, LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(a.objects_modified, ARRAY_CONSTRUCT()),
                                                 COALESCE(a.direct_objects_accessed, ARRAY_CONSTRUCT()))) f
  WHERE f.value:"stageKind" IS NOT NULL OR UPPER(f.value:"objectDomain"::STRING) = 'STAGE'
  GROUP BY a.query_id
),
src AS (
  SELECT DISTINCT a.query_id, UPPER(f.value:"objectName"::STRING) AS table_fqn
  FROM ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  WHERE UPPER(f.value:"objectDomain"::STRING) IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'EXTERNAL TABLE',
                                                  'MATERIALIZED VIEW')
),
sens AS (
  SELECT DISTINCT database_name || '.' || schema_name || '.' || table_name AS table_fqn FROM sf_gov_sensitive_columns
),
src_s AS (
  SELECT s.query_id, s.table_fqn, x.table_fqn IS NOT NULL AS is_sensitive
  FROM src s LEFT JOIN sens x ON x.table_fqn = s.table_fqn
),
ss AS (
  SELECT session_id, MAX(SPLIT_PART(client_application_id, ' ', 1)) AS client
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  WHERE session_id IN (SELECT session_id FROM q)
  GROUP BY session_id
),
rows_q AS (
  SELECT q.*, DATE(q.start_time) AS usage_date, COALESCE(NULLIF(ss.client, ''), 'unknown') AS client,
         COALESCE(st.stage_name, '(not in ACCESS_HISTORY)') AS stage_name
  FROM q
  LEFT JOIN ss ON ss.session_id = q.session_id
  LEFT JOIN stages st ON st.query_id = q.query_id
),
-- stages that an unload of a sensitive table wrote to: a later GET from them takes that data out
sens_stages AS (
  SELECT DISTINCT r.stage_name
  FROM rows_q r JOIN src_s s ON s.query_id = r.query_id AND s.is_sensitive
  WHERE r.kind = 'UNLOAD'
),
g AS (
  SELECT r.usage_date, r.user_name, r.role_name, r.client, r.kind, r.stage_name,
         COUNT(DISTINCT r.query_id) AS queries, SUM(r.rows_unloaded) AS rows_unloaded,
         SUM(r.outbound_bytes) / POWER(1024, 3) AS outbound_gb,
         MIN(r.start_time) AS first_at, MAX(r.start_time) AS last_at
  FROM rows_q r
  GROUP BY 1, 2, 3, 4, 5, 6
),
t AS (
  SELECT r.usage_date, r.user_name, r.role_name, r.client, r.kind, r.stage_name,
         COUNT(DISTINCT s.table_fqn) AS source_table_count,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT s.table_fqn) WITHIN GROUP (ORDER BY s.table_fqn), 0, 10), ', ') AS source_tables,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT IFF(s.is_sensitive, s.table_fqn, NULL))
                         WITHIN GROUP (ORDER BY IFF(s.is_sensitive, s.table_fqn, NULL)), 0, 10), ', ') AS sensitive_tables,
         COUNT(DISTINCT IFF(s.is_sensitive, s.table_fqn, NULL)) AS sensitive_table_count
  FROM rows_q r JOIN src_s s ON s.query_id = r.query_id
  GROUP BY 1, 2, 3, 4, 5, 6
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, g.usage_date, g.user_name,
       COALESCE(u.user_type, 'UNKNOWN') AS user_type, g.role_name, g.client, g.kind, g.stage_name,
       g.queries, g.rows_unloaded, g.outbound_gb, COALESCE(t.source_table_count, 0) AS source_table_count,
       NULLIF(t.source_tables, '') AS source_tables, NULLIF(t.sensitive_tables, '') AS sensitive_tables,
       COALESCE(t.sensitive_table_count, 0) AS sensitive_table_count,
       ss2.stage_name IS NOT NULL AS stage_had_sensitive_unload, g.first_at, g.last_at,
       CASE WHEN COALESCE(u.user_type, 'UNKNOWN') IN ('SERVICE', 'LEGACY_SERVICE') THEN 'OK'
            WHEN COALESCE(t.sensitive_table_count, 0) > 0 THEN 'WARN'
            WHEN g.kind = 'GET' AND ss2.stage_name IS NOT NULL THEN 'WARN'
            ELSE 'OK' END AS status
FROM g
LEFT JOIN t ON t.usage_date = g.usage_date AND t.user_name IS NOT DISTINCT FROM g.user_name
 AND t.role_name IS NOT DISTINCT FROM g.role_name AND t.client = g.client AND t.kind = g.kind
 AND t.stage_name = g.stage_name
LEFT JOIN sf_sec_users u ON u.user_name = g.user_name
LEFT JOIN sens_stages ss2 ON ss2.stage_name = g.stage_name AND ss2.stage_name <> '(not in ACCESS_HISTORY)'
ORDER BY g.usage_date DESC, g.user_name, g.kind
