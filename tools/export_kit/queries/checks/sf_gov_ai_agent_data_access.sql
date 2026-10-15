-- query_id: sf_gov_ai_agent_data_access
-- title: Tables AI agents read, and the sensitive columns among them
-- domain: governance_access   tier: standard
-- windowed: yes
-- entity: tables = table_fqn
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (Access History)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export date
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. agents_info is a newer ACCESS_HISTORY column; an account
--   whose view does not have it yet reads Not assessed.
-- read_this: one row = one agent x one base table it read in the window. agent_type is the agent nearest
--   the access in ACCESS_HISTORY.agents_info: CORTEX_AGENT (a named Cortex Agent, agent_name is its
--   name), CORTEX_LITE_AGENT (the REST API or a Snowflake client, no name) or EXTERNAL_AGENT (a
--   SERVICE_AGENT user or an OAuth integration marked agentic). queries and users count the queries and
--   distinct users behind the reads. sensitive_columns counts the columns read that carry a sensitive tag
--   (see sf_gov_sensitive_columns_unprotected); unmasked_columns names those no masking policy covers.
-- healthy: status = OK when the agent read no sensitive column, or only masked ones, and is not external.
-- investigate_if: WARN when an external agent read the table, or an agent read masked sensitive columns;
--   CRITICAL when an agent read a sensitive column no masking policy covers.
-- actions: 1) give each agent its own role and grant it only the tables it needs (free); 2) mask the
--   sensitive columns agents read, allowing clear text only to named roles (config); 3) review the external
--   agents' OAuth integrations and SERVICE_AGENT users, and drop those no one owns (free)
-- next: sf_gov_sensitive_data_access, sf_gov_sensitive_columns_unprotected
-- caveats: heavy: reads ACCESS_HISTORY for the window (period_days only) and flattens the objects each
--   query read. ACCESS_HISTORY lags up to 3 hours. Only tagged columns count as sensitive; a read of a masked
--   column may still have returned clear text to a role the policy allows. Query text is never read.
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
ah AS (
  -- the agent nearest the access is the array's first element
  SELECT h.query_id, h.user_name, h.query_start_time, h.base_objects_accessed,
         UPPER(a.value:"agentType"::VARCHAR) AS agent_type,
         COALESCE(a.value:"agentName"::VARCHAR, a.value:"agentId"::VARCHAR) AS agent_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY h, LATERAL FLATTEN(input => h.agents_info) a
  WHERE h.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND h.query_start_time < __AS_OF_DATE__
    AND a.index = 0
),
reads AS (
  SELECT ah.query_id, ah.user_name, ah.query_start_time, ah.agent_type, ah.agent_name,
         REPLACE(UPPER(obj.value:"objectName"::VARCHAR), '"', '') AS table_fqn,
         UPPER(col.value:"columnName"::VARCHAR) AS column_name
  FROM ah,
       LATERAL FLATTEN(input => ah.base_objects_accessed) obj,
       LATERAL FLATTEN(input => obj.value:"columns", OUTER => TRUE) col
  WHERE UPPER(obj.value:"objectDomain"::VARCHAR) IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'DYNAMIC TABLE', 'EXTERNAL TABLE')
),
hits AS (
  SELECT r.*, s.column_name IS NOT NULL AS is_sensitive, s.masking_policies IS NOT NULL AS is_masked
  FROM reads r
  LEFT JOIN sf_gov_sensitive_columns s
    ON r.table_fqn = s.database_name || '.' || s.schema_name || '.' || s.table_name AND r.column_name = s.column_name
),
g AS (
  SELECT agent_type, COALESCE(agent_name, '(' || LOWER(agent_type) || ')') AS agent_name, table_fqn,
         SPLIT_PART(table_fqn, '.', 1) AS database_name,
         COUNT(DISTINCT query_id) AS queries, COUNT(DISTINCT user_name) AS users,
         COUNT(DISTINCT IFF(is_sensitive, column_name, NULL)) AS sensitive_columns,
         LISTAGG(DISTINCT IFF(is_sensitive AND NOT is_masked, column_name, NULL), ', ') AS unmasked_columns,
         MIN(query_start_time) AS first_read, MAX(query_start_time) AS last_read
  FROM hits
  GROUP BY 1, 2, 3, 4
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, agent_type, agent_name, table_fqn, database_name,
       queries, users, sensitive_columns, NULLIF(unmasked_columns, '') AS unmasked_columns, first_read, last_read,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NULLIF(unmasked_columns, '') IS NOT NULL, 'unmasked sensitive: ' || unmasked_columns, NULL),
         IFF(sensitive_columns > 0 AND NULLIF(unmasked_columns, '') IS NULL, sensitive_columns || ' masked sensitive columns', NULL),
         IFF(agent_type = 'EXTERNAL_AGENT', 'external agent', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE WHEN NULLIF(unmasked_columns, '') IS NOT NULL THEN 'CRITICAL'
            WHEN agent_type = 'EXTERNAL_AGENT' OR sensitive_columns > 0 THEN 'WARN'
            ELSE 'OK' END AS status
FROM g
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, queries DESC, agent_name, table_fqn
