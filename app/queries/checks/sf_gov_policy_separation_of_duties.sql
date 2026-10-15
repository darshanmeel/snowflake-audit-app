-- query_id: sf_gov_policy_separation_of_duties
-- title: Masking and row access policies owned by the same role as the data they protect
-- domain: governance_access   tier: standard
-- windowed: no
-- entity: tables = table_fqn
-- reads: SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES,
--   SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES, SNOWFLAKE.ACCOUNT_USAGE.TAGS, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (masking, row access, tags)
-- params: none
-- empty_if: edition_too_low, role_cannot_see
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table x one masking or row access policy that protects it, directly or through
--   a tag set on the table or its columns. table_owner, policy_owner and tag_owner are the roles that own
--   each. same_owner is true when the table's owner also owns the policy or the tag that carries it: that
--   role can change or drop the protection on its own data. sensitive is true when the table has a column
--   tagged sensitive. Policy bodies are never read.
-- healthy: status = OK when a different role owns the policy (and its tag) than the table.
-- investigate_if: WARN when the table's owner also owns the policy or its tag; CRITICAL when that table
--   holds sensitive columns.
-- actions: 1) move policy and tag ownership to a governance role that owns no data:
--   GRANT OWNERSHIP ON MASKING POLICY ... TO ROLE <governance role> (free); 2) grant APPLY MASKING POLICY
--   and APPLY TAG only to that role (free)
-- next: sf_gov_ownership_concentration, sf_gov_privacy_policies_unattached
-- caveats: POLICY_REFERENCES does not list session, password or authentication policies; they are not
--   judged. Owners are roles; a role inherited by the table owner is not followed. ACCOUNT_USAGE lags up to
--   2 hours.
WITH __INCLUDE_sf_gov_sensitive_columns__,
pol AS (
  SELECT policy_id, policy_owner, 'MASKING_POLICY' AS kind FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES WHERE deleted IS NULL
  UNION ALL
  SELECT policy_id, policy_owner, 'ROW_ACCESS_POLICY' AS kind FROM SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES WHERE deleted IS NULL
),
pr AS (
  SELECT policy_id, UPPER(policy_kind) AS policy_kind, policy_db || '.' || policy_schema || '.' || policy_name AS policy_fqn,
         UPPER(ref_database_name) AS ref_db, UPPER(ref_schema_name) AS ref_schema, UPPER(ref_entity_name) AS ref_entity,
         UPPER(ref_entity_domain) AS ref_domain, UPPER(tag_database) AS tag_db, UPPER(tag_schema) AS tag_schema,
         UPPER(tag_name) AS tag_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  WHERE UPPER(policy_kind) IN ('MASKING_POLICY', 'ROW_ACCESS_POLICY')
),
tagged AS (
  -- a policy set on a tag protects every table the tag is on, or whose columns carry it
  SELECT DISTINCT UPPER(tag_database) AS tag_db, UPPER(tag_schema) AS tag_schema, UPPER(tag_name) AS tag_name,
         UPPER(object_database) AS ref_db, UPPER(object_schema) AS ref_schema, UPPER(object_name) AS ref_entity
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL AND UPPER(domain) IN ('TABLE', 'COLUMN')
),
prot AS (
  SELECT pr.policy_id, pr.policy_kind, pr.policy_fqn, pr.ref_db, pr.ref_schema, pr.ref_entity, pr.tag_db, pr.tag_schema, pr.tag_name
  FROM pr WHERE pr.ref_domain <> 'TAG'
  UNION
  SELECT pr.policy_id, pr.policy_kind, pr.policy_fqn, tg.ref_db, tg.ref_schema, tg.ref_entity, pr.tag_db, pr.tag_schema, pr.tag_name
  FROM pr JOIN tagged tg ON tg.tag_db = pr.ref_db AND tg.tag_schema = pr.ref_schema AND tg.tag_name = pr.ref_entity
  WHERE pr.ref_domain = 'TAG'
),
tb AS (
  SELECT UPPER(table_catalog) AS db, UPPER(table_schema) AS sch, UPPER(table_name) AS tbl, table_owner, TO_VARCHAR(table_id) AS table_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES WHERE deleted IS NULL
),
tg AS (
  SELECT UPPER(tag_database) AS db, UPPER(tag_schema) AS sch, UPPER(tag_name) AS name, MAX(tag_owner) AS tag_owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAGS WHERE deleted IS NULL GROUP BY 1, 2, 3
),
sens AS (
  SELECT DISTINCT database_name AS db, schema_name AS sch, table_name AS tbl FROM sf_gov_sensitive_columns
),
s AS (
  SELECT prot.ref_db || '.' || prot.ref_schema || '.' || prot.ref_entity AS table_fqn, tb.table_id, prot.ref_db AS database_name,
         tb.table_owner, prot.policy_kind, prot.policy_fqn, pol.policy_owner,
         IFF(prot.tag_name IS NULL, NULL, prot.tag_db || '.' || prot.tag_schema || '.' || prot.tag_name) AS via_tag, tg.tag_owner,
         sens.tbl IS NOT NULL AS sensitive,
         COALESCE(tb.table_owner = pol.policy_owner, FALSE) OR COALESCE(tb.table_owner = tg.tag_owner, FALSE) AS same_owner
  FROM prot
  JOIN tb ON tb.db = prot.ref_db AND tb.sch = prot.ref_schema AND tb.tbl = prot.ref_entity
  LEFT JOIN pol ON pol.policy_id = prot.policy_id
  LEFT JOIN tg ON tg.db = prot.tag_db AND tg.sch = prot.tag_schema AND tg.name = prot.tag_name
  LEFT JOIN sens ON sens.db = prot.ref_db AND sens.sch = prot.ref_schema AND sens.tbl = prot.ref_entity
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, table_fqn, table_id, database_name, table_owner, policy_kind,
       policy_fqn, policy_owner, via_tag, tag_owner, sensitive, same_owner,
       IFF(same_owner, table_owner || ' owns the table and the '
           || IFF(table_owner = policy_owner, 'policy', 'tag ' || via_tag), NULL) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE WHEN NOT same_owner THEN 'OK' WHEN sensitive THEN 'CRITICAL' ELSE 'WARN' END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, table_fqn, policy_fqn
