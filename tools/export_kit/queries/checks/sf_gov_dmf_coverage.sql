-- query_id: sf_gov_dmf_coverage
-- title: Tables watched by a data metric function, per database
-- domain: governance_access   tier: standard
-- entity: databases = database_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.TABLES,
--   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (data metric functions, tags)
-- params: :min_tables (default 10) tables: a database with fewer is not flagged for low coverage; :warn_pct
--   (default 10) percent: coverage below this flags
-- empty_if: edition_too_low, role_cannot_see
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. How a schema-level association is listed (which entity name it
--   carries) is not stated in the docs, so it is matched on database and schema only.
-- read_this: one row = one database. base_tables is every live base table; covered_tables those with a data
--   metric function attached to the table or to its schema; active_tables those with a schedule that is running.
--   sensitive_tables counts tables with a column tagged sensitive, and sensitive_uncovered those with no
--   function. The cost of the functions is on the observability cost page, not here.
-- healthy: status = OK when data quality monitoring is not used in the account, or the database is small or
--   covered, and its sensitive tables are covered.
-- investigate_if: WARN when the account uses data metric functions and a database with :min_tables tables or
--   more has coverage under :warn_pct percent, all its functions are suspended, or a sensitive table has none.
-- actions: 1) attach NULL_COUNT, DUPLICATE_COUNT or FRESHNESS to the tables that feed reports, starting with the
--   sensitive ones (config); 2) resume suspended schedules or drop the association (free); 3) set the schedule
--   on the table (TRIGGER_ON_CHANGES or a cron) so it costs only when data changes (config)
-- next: sf_acct_observability_cost
-- caveats: An account with no data metric function at all reads OK on every row: it does not use the feature.
--   Views are not counted as tables. Tables in shared or imported databases may be missing from TABLES. The
--   function text is never read. ACCOUNT_USAGE lags up to 3 hours.
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
t AS (
  SELECT UPPER(tb.table_catalog) AS db_key, tb.table_catalog AS database_name, UPPER(tb.table_schema) AS sch_key,
         UPPER(tb.table_name) AS tbl_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES tb
  WHERE tb.deleted IS NULL AND tb.table_type = 'BASE TABLE' AND UPPER(tb.table_catalog) <> 'SNOWFLAKE'
),
d AS (
  SELECT UPPER(ref_database_name) AS db_key, UPPER(ref_schema_name) AS sch_key, UPPER(ref_entity_name) AS tbl_key,
         UPPER(COALESCE(level, 'TABLE')) AS lvl, BOOLOR_AGG(UPPER(COALESCE(schedule_status, '')) LIKE 'STARTED%') AS started
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_REFERENCES
  GROUP BY 1, 2, 3, 4
),
dt AS (SELECT db_key, sch_key, tbl_key, started FROM d WHERE lvl = 'TABLE'),
ds AS (SELECT db_key, sch_key, BOOLOR_AGG(started) AS started FROM d WHERE lvl = 'SCHEMA' GROUP BY 1, 2),
sens AS (
  SELECT DISTINCT UPPER(database_name) AS db_key, UPPER(schema_name) AS sch_key, UPPER(table_name) AS tbl_key
  FROM sf_gov_sensitive_columns
),
uses AS (
  SELECT COUNT(*) > 0 AS account_uses_dmf FROM d
),
tt AS (
  SELECT t.db_key, t.database_name,
         dt.tbl_key IS NOT NULL OR ds.sch_key IS NOT NULL AS covered,
         COALESCE(dt.started, FALSE) OR COALESCE(ds.started, FALSE) AS active,
         sens.tbl_key IS NOT NULL AS is_sensitive
  FROM t
  LEFT JOIN dt ON dt.db_key = t.db_key AND dt.sch_key = t.sch_key AND dt.tbl_key = t.tbl_key
  LEFT JOIN ds ON ds.db_key = t.db_key AND ds.sch_key = t.sch_key
  LEFT JOIN sens ON sens.db_key = t.db_key AND sens.sch_key = t.sch_key AND sens.tbl_key = t.tbl_key
),
a AS (
  SELECT db_key, MAX(database_name) AS database_name, COUNT(*) AS base_tables, COUNT_IF(covered) AS covered_tables,
         COUNT_IF(active) AS active_tables, COUNT_IF(is_sensitive) AS sensitive_tables,
         COUNT_IF(is_sensitive AND NOT covered) AS sensitive_uncovered
  FROM tt
  GROUP BY db_key
),
s AS (
  SELECT a.*, 100 * covered_tables / NULLIF(base_tables, 0) AS coverage_pct, u.account_uses_dmf,
         u.account_uses_dmf AND base_tables >= :min_tables AND 100 * covered_tables / NULLIF(base_tables, 0) < :warn_pct AS low,
         u.account_uses_dmf AND covered_tables > 0 AND active_tables = 0 AS all_suspended,
         u.account_uses_dmf AND sensitive_uncovered > 0 AS sensitive_gap
  FROM a CROSS JOIN uses u
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, database_name, base_tables, covered_tables, active_tables,
       coverage_pct, sensitive_tables, sensitive_uncovered,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NOT account_uses_dmf, 'no data metric function in the account', NULL),
         IFF(low, covered_tables || ' of ' || base_tables || ' tables covered', NULL),
         IFF(all_suspended, 'every function is suspended', NULL),
         IFF(sensitive_gap, sensitive_uncovered || ' sensitive tables with no function', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(low OR all_suspended OR sensitive_gap, 'WARN', 'OK') AS status
FROM s
ORDER BY IFF(low OR all_suspended OR sensitive_gap, 0, 1), base_tables DESC, database_name
