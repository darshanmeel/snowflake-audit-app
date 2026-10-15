-- query_id: sf_secx_sensitive_lineage_untagged
-- title: Sensitive columns copied into columns with no tag or mask
-- domain: governance_access   tier: standard
-- entity: columns = target_table, target_column
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (GOVERNANCE_VIEWER); Enterprise edition
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- empty_if: edition_too_low, role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Object names are split on dots, so quoted names
--   with dots are missed.
-- read_this: one row = one copy path from a sensitive source column to a target column written by a query in the
--   window. Sensitive = tagged with a classification tag or a custom PII-style tag (see
--   sf_gov_sensitive_columns_unprotected). source_masked says a masking policy reaches the source;
--   target_tagged and target_masked say the same for the target. queries counts distinct writing
--   queries. Only visible tags and policies are considered.
-- healthy: status = OK when the target column is tagged sensitive or masked.
-- investigate_if: WARN when a sensitive column is copied into a column with no sensitive tag and no
--   masking policy; CRITICAL when the source is masked and the target is neither.
-- actions: 1) tag the target column, or run classification on its schema (config); 2) set a tag-based
--   masking policy so copies are covered at once (config); 3) review the writing job with its owner
--   (free)
-- next: sf_gov_sensitive_columns_unprotected
-- caveats: ACCESS_HISTORY needs Enterprise edition and lags up to 3 hours; only column lineage of
--   writes is read (queries from a masked role may copy masked values, which still counts). TAG and
--   POLICY references show only what the role can see. Query text is never read.
WITH __INCLUDE_sf_gov_sensitive_columns__,
edges AS (
  SELECT ah.query_id, ah.user_name,
         UPPER(SPLIT_PART(obj.value:objectName::VARCHAR, '.', 1)) AS t_db,
         UPPER(SPLIT_PART(obj.value:objectName::VARCHAR, '.', 2)) AS t_schema,
         UPPER(SPLIT_PART(obj.value:objectName::VARCHAR, '.', 3)) AS t_table,
         UPPER(col.value:columnName::VARCHAR) AS t_column,
         UPPER(SPLIT_PART(src.value:objectName::VARCHAR, '.', 1)) AS s_db,
         UPPER(SPLIT_PART(src.value:objectName::VARCHAR, '.', 2)) AS s_schema,
         UPPER(SPLIT_PART(src.value:objectName::VARCHAR, '.', 3)) AS s_table,
         UPPER(src.value:columnName::VARCHAR) AS s_column
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(INPUT => ah.objects_modified, OUTER => TRUE) obj,
       LATERAL FLATTEN(INPUT => obj.value:columns, OUTER => TRUE) col,
       LATERAL FLATTEN(INPUT => col.value:baseSources, OUTER => TRUE) src
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND ah.query_start_time < __AS_OF_DATE__
),
-- Distinct paths per query first, so a query that touches a path twice counts once.
paths AS (
  SELECT DISTINCT query_id, user_name, t_db, t_schema, t_table, t_column, s_db, s_schema, s_table, s_column
  FROM edges
  WHERE s_column IS NOT NULL AND t_column IS NOT NULL
    AND NOT (t_db = s_db AND t_schema = s_schema AND t_table = s_table)
),
-- Columns with a masking policy attached straight to them, whether or not they are tagged.
direct_mask AS (
  SELECT DISTINCT ref_database_name AS db, ref_schema_name AS schema_name, ref_entity_name AS table_name,
         ref_column_name AS column_name
  FROM sf_gov_policy_refs
  WHERE policy_kind = 'MASKING_POLICY' AND ref_column_name IS NOT NULL
),
agg AS (
  SELECT p.s_db, p.s_schema, p.s_table, p.s_column, p.t_db, p.t_schema, p.t_table, p.t_column,
         COUNT(DISTINCT p.query_id) AS queries, COUNT(DISTINCT p.user_name) AS users
  FROM paths p
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),
j AS (
  SELECT a.*, s.privacy_category, s.semantic_category, s.custom_tags,
         s.masking_policies IS NOT NULL AS source_masked,
         t.column_name IS NOT NULL AS target_tagged,
         (t.masking_policies IS NOT NULL OR dm.column_name IS NOT NULL) AS target_masked
  FROM agg a
  JOIN sf_gov_sensitive_columns s
    ON s.database_name = a.s_db AND s.schema_name = a.s_schema AND s.table_name = a.s_table AND s.column_name = a.s_column
  LEFT JOIN sf_gov_sensitive_columns t
    ON t.database_name = a.t_db AND t.schema_name = a.t_schema AND t.table_name = a.t_table AND t.column_name = a.t_column
  LEFT JOIN direct_mask dm
    ON dm.db = a.t_db AND dm.schema_name = a.t_schema AND dm.table_name = a.t_table AND dm.column_name = a.t_column
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       s_db || '.' || s_schema || '.' || s_table AS source_table, s_column AS source_column,
       t_db || '.' || t_schema || '.' || t_table AS target_table, t_column AS target_column,
       privacy_category, semantic_category, custom_tags, source_masked, target_tagged, target_masked, queries, users,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(NOT target_tagged AND NOT target_masked, 'target has no sensitive tag and no masking policy', NULL),
         IFF(source_masked AND NOT target_masked, 'source is masked, target is not', NULL),
         IFF(privacy_category IS NOT NULL, 'source privacy category ' || privacy_category, NULL),
         IFF(semantic_category IS NOT NULL, 'source semantic category ' || semantic_category, NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN target_tagged OR target_masked THEN 'OK'
         WHEN source_masked THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, queries DESC, source_table, target_table
