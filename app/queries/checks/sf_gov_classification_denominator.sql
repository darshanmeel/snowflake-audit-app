-- query_id: sf_gov_classification_denominator
-- title: Columns carrying a sensitive or semantic tag, out of all columns, per database
-- domain: governance_access   tier: standard
-- entity: databases = database_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.COLUMNS, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (tags and masking policies)
-- params: :min_columns (default 50) columns: a database with fewer is never flagged
-- empty_if: edition_too_low, role_cannot_see
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. COLUMNS is large; the count is one pass over it.
-- read_this: one row = one database. total_columns is every live column in it (tables and views), tagged_columns
--   those carrying Snowflake's SEMANTIC_CATEGORY or PRIVACY_CATEGORY tag or a custom sensitive tag, masked_columns
--   the tagged ones a masking policy reaches. tagged_pct = tagged_columns / total_columns. It is the
--   denominator for "N of M columns classified"; a low share is normal, since most columns are not sensitive.
-- healthy: status = OK when the database has tagged columns, or it is small.
-- investigate_if: WARN when a database with at least :min_columns columns has no tagged column at all: nothing
--   is known about what is sensitive in it.
-- actions: 1) run classification on the databases that hold customer data (SYSTEM$CLASSIFY, or a
--   classification profile) (free); 2) apply the recommended tags (config); 3) put masking policies on the tags
--   so tagged columns are masked (config)
-- next: sf_gov_classification_coverage
-- caveats: Only columns of live tables and views are counted; shared and imported databases may be missing
--   from COLUMNS. INFORMATION_SCHEMA and the SNOWFLAKE database are left out. Database names are matched
--   ignoring case. Tag masking through a tag the column does not carry is not seen.
WITH __INCLUDE_sf_gov_sensitive_columns__,
c AS (
  SELECT UPPER(col.table_catalog) AS db_key, MAX(col.table_catalog) AS database_name, COUNT(*) AS total_columns,
         COUNT(DISTINCT col.table_schema || '.' || col.table_name) AS objects
  FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS col
  WHERE col.deleted IS NULL AND UPPER(col.table_catalog) <> 'SNOWFLAKE' AND UPPER(col.table_schema) <> 'INFORMATION_SCHEMA'
  GROUP BY 1
),
t AS (
  SELECT UPPER(database_name) AS db_key, COUNT(*) AS tagged_columns, COUNT_IF(masking_policies IS NOT NULL) AS masked_columns
  FROM sf_gov_sensitive_columns
  GROUP BY 1
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, c.database_name, c.objects AS tables_and_views, c.total_columns,
       COALESCE(t.tagged_columns, 0) AS tagged_columns, COALESCE(t.masked_columns, 0) AS masked_columns,
       100 * COALESCE(t.tagged_columns, 0) / NULLIF(c.total_columns, 0) AS tagged_pct,
       IFF(COALESCE(t.tagged_columns, 0) = 0 AND c.total_columns >= :min_columns,
           'no column carries a sensitive or semantic tag', NULL) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(COALESCE(t.tagged_columns, 0) = 0 AND c.total_columns >= :min_columns, 'WARN', 'OK') AS status
FROM c
LEFT JOIN t ON t.db_key = c.db_key
ORDER BY IFF(COALESCE(t.tagged_columns, 0) = 0 AND c.total_columns >= :min_columns, 0, 1), c.total_columns DESC, c.database_name
