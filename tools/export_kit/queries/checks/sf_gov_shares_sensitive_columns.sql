-- query_id: sf_gov_shares_sensitive_columns
-- title: Outbound shares that carry columns tagged sensitive
-- domain: governance_access   tier: standard
-- entity: shares = share_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES, SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES,
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (tags and masking policies)
-- params: :sample_size (default 5) tables: how many table names a row lists as examples
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_sensitive_tags: no column in the account carries a sensitive or semantic tag, so what a
--   share exposes cannot be judged
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. How a masking policy behaves for a share consumer is not settled
--   here, so masked columns are flagged at a lower level, not cleared.
-- read_this: one row = one outbound share with SELECT granted on tables or views. shared_objects counts them;
--   sensitive_columns counts columns tagged sensitive in those tables and in the tables a shared view reads
--   (one level down); unmasked_sensitive_columns are those no masking policy reaches. sample_tables names a few.
-- healthy: status = OK when no shared table has a sensitive column.
-- investigate_if: WARN when a shared table has sensitive columns that are all masked (check the policy applies for
--   the consumer); CRITICAL when a shared table has a sensitive column with no masking policy.
-- actions: 1) share a secure view that leaves the sensitive columns out instead of the table (config);
--   2) remove the grant from the share, ALTER SHARE ... REVOKE SELECT (free); 3) confirm with the data owner
--   and the consumer that the columns are needed (free)
-- next: sf_gov_shares_and_listings
-- caveats: Only tagged columns are known sensitive: an untagged column reads as not sensitive, so the answer is
--   only as complete as the classification. A view that reads another view is followed one level only. Shares
--   with no SELECT grant are not listed. GRANTS_TO_SHARES lags up to 3 hours.
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
g AS (
  SELECT gs.share_name, UPPER(gs.object_database) AS db_key, UPPER(gs.object_schema) AS sch_key,
         UPPER(SPLIT_PART(gs.object_name, '.', -1)) AS obj_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_SHARES gs
  WHERE gs.deleted_on IS NULL AND UPPER(gs.privilege) = 'SELECT'
),
src AS (
  SELECT share_name, db_key, sch_key, obj_key, FALSE AS via_view FROM g
  UNION ALL
  SELECT g.share_name, UPPER(d.referenced_database), UPPER(d.referenced_schema), UPPER(d.referenced_object_name), TRUE
  FROM g
  JOIN SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES d
    ON UPPER(d.referencing_database) = g.db_key AND UPPER(d.referencing_schema) = g.sch_key
   AND UPPER(d.referencing_object_name) = g.obj_key
),
sens AS (
  SELECT UPPER(database_name) AS db_key, UPPER(schema_name) AS sch_key, UPPER(table_name) AS obj_key,
         COUNT(*) AS sensitive_columns, COUNT_IF(masking_policies IS NULL) AS unmasked_columns
  FROM sf_gov_sensitive_columns
  GROUP BY 1, 2, 3
),
o AS (
  SELECT src.share_name, src.db_key, src.sch_key, src.obj_key, BOOLAND_AGG(src.via_view) AS via_view,
         MAX(COALESCE(s.sensitive_columns, 0)) AS sensitive_columns, MAX(COALESCE(s.unmasked_columns, 0)) AS unmasked_columns
  FROM src
  LEFT JOIN sens s ON s.db_key = src.db_key AND s.sch_key = src.sch_key AND s.obj_key = src.obj_key
  GROUP BY src.share_name, src.db_key, src.sch_key, src.obj_key
),
ranked AS (
  SELECT o.*, ROW_NUMBER() OVER (PARTITION BY share_name ORDER BY unmasked_columns DESC, sensitive_columns DESC, obj_key) AS rn
  FROM o
  WHERE sensitive_columns > 0
),
a AS (
  SELECT share_name, COUNT(DISTINCT IFF(NOT via_view, db_key || '.' || sch_key || '.' || obj_key, NULL)) AS shared_objects,
         COUNT(DISTINCT IFF(sensitive_columns > 0, db_key || '.' || sch_key || '.' || obj_key, NULL)) AS objects_with_sensitive,
         SUM(sensitive_columns) AS sensitive_columns, SUM(unmasked_columns) AS unmasked_sensitive_columns
  FROM o
  GROUP BY share_name
),
smp AS (
  SELECT share_name,
         LISTAGG(IFF(rn <= :sample_size, db_key || '.' || sch_key || '.' || obj_key, NULL), ', ') AS sample_tables
  FROM ranked
  GROUP BY share_name
),
tagged AS (
  SELECT COUNT(*) > 0 AS any_tagged FROM sf_gov_sensitive_columns
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, a.share_name, a.shared_objects, a.objects_with_sensitive,
       a.sensitive_columns, a.unmasked_sensitive_columns, sm.sample_tables,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(a.unmasked_sensitive_columns > 0, a.unmasked_sensitive_columns || ' sensitive columns with no masking policy', NULL),
         IFF(a.sensitive_columns > 0 AND a.unmasked_sensitive_columns = 0, a.sensitive_columns || ' sensitive columns, all masked', NULL)), '; ') AS reasons,
       IFF(NOT tg.any_tagged, 'no_sensitive_tags', NULL) AS not_assessed_reason,
       CASE
         WHEN NOT tg.any_tagged THEN 'NOT_ASSESSED'
         WHEN a.unmasked_sensitive_columns > 0 THEN 'CRITICAL'
         WHEN a.sensitive_columns > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM a
LEFT JOIN smp sm ON sm.share_name = a.share_name
CROSS JOIN tagged tg
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END,
         a.unmasked_sensitive_columns DESC, a.share_name
