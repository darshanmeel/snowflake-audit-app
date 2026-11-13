-- query_id: sf_gov_tag_objects
-- title: Which databases, schemas, tables and columns carry each tag
-- domain: governance_access   tier: standard
-- entity: tagged objects = tag_fqn, tag_value, level, database_name, schema_name, table_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition for tags
-- params: :row_cap (default 200000) rows: the export keeps at most this many
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one tag value set directly on one database, schema or table (views included), or
--   on columns of one table (level COLUMN, with the columns listed). A tag on a database or schema also
--   reaches every table in it by inheritance; that row stands for all of them. apply_method is MANUAL,
--   CLASSIFIED (set by Snowflake classification) or PROPAGATED. Tag names and values only.
-- healthy: status = OK on every row; this check is an inventory for the tag explorer.
-- investigate_if: n/a - inventory
-- actions: 1) pick a tag on PII › Tags to see who can reach its tables and who queried them (free)
-- next: sf_acc_sensitive_reach
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- caveats: TAG_REFERENCES lists direct assignments only and lags up to 2 hours; the role sees only the
--   objects it can access. Tags on warehouses, users and roles are on the Tags page.
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       UPPER(tag_database || '.' || tag_schema || '.' || tag_name) AS tag_fqn, COALESCE(tag_value, '') AS tag_value,
       IFF(UPPER(domain) = 'COLUMN', 'COLUMN', UPPER(domain)) AS level,
       UPPER(CASE UPPER(domain) WHEN 'DATABASE' THEN object_name ELSE object_database END) AS database_name,
       UPPER(CASE UPPER(domain) WHEN 'SCHEMA' THEN object_name WHEN 'DATABASE' THEN NULL ELSE object_schema END) AS schema_name,
       UPPER(IFF(UPPER(domain) IN ('TABLE', 'COLUMN'), object_name, NULL)) AS table_name,
       LISTAGG(DISTINCT UPPER(column_name), ', ') WITHIN GROUP (ORDER BY UPPER(column_name)) AS columns,
       COUNT(DISTINCT column_name) AS column_count,
       LISTAGG(DISTINCT apply_method, ', ') AS apply_method, 'OK' AS status
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE object_deleted IS NULL AND tag_name IS NOT NULL
  AND UPPER(domain) IN ('DATABASE', 'SCHEMA', 'TABLE', 'COLUMN')
GROUP BY 3, 4, 5, 6, 7, 8
ORDER BY tag_fqn, tag_value, database_name, schema_name, table_name
