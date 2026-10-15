-- query_id: sf_gov_tag_hygiene
-- title: Tags nobody uses, look-alike tags and values that differ only in spelling
-- domain: governance_access   tier: standard
-- entity: tags = tag_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TAGS, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (tags); TAGS lists only tags the
--   role can see
-- params: :grace_days (default 30) days: a tag younger than this is not called unused; :free_values (default 20)
--   values: a tag with no allowed-value list and at least this many distinct values flags
-- empty_if: edition_too_low, role_cannot_see
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one tag you defined (the SNOWFLAKE.CORE tags are left out). tag_references is
--   how many live objects and columns carry it; distinct_values how many values are set. lookalike_tags counts
--   tags whose name is the same once case, underscores and dashes are ignored (COST_CENTER, CostCenter).
--   value_variants counts values that differ from another only by case or spaces (Finance, finance).
--   has_allowed_values is TRUE when the tag restricts what can be set.
-- healthy: status = OK when the tag is used, has one spelling and either restricts its values or has few.
-- investigate_if: WARN when the tag has no references and is older than :grace_days, has look-alike tags,
--   has value variants, or has no allowed values and :free_values or more distinct values.
-- actions: 1) drop tags nobody uses and merge look-alikes into one (free); 2) add ALLOWED_VALUES to the tags
--   that drive chargeback so a typo cannot open a new bucket (config); 3) fix the variant values with
--   ALTER ... SET TAG on the objects that carry them (free)
-- next: sf_chg_tag_coverage
-- caveats: TAGS shows only tags the role can see, so a partial list is not "no other tags". Tag values are
--   counted and compared here, never stored. References on deleted objects are left out. A look-alike can be
--   the same tag in another schema on purpose.
WITH t AS (
  SELECT tg.tag_id, tg.tag_database, tg.tag_schema, tg.tag_name, tg.tag_owner, tg.created,
         tg.allowed_values IS NOT NULL AND ARRAY_SIZE(tg.allowed_values) > 0 AS has_allowed_values,
         REGEXP_REPLACE(UPPER(tg.tag_name), '[^A-Z0-9]', '') AS name_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAGS tg
  WHERE tg.deleted IS NULL
),
r AS (
  SELECT UPPER(tag_database) AS tag_database, UPPER(tag_schema) AS tag_schema, UPPER(tag_name) AS tag_name,
         COUNT(*) AS refs, COUNT(DISTINCT tag_value) AS distinct_values,
         COUNT(DISTINCT UPPER(TRIM(tag_value))) AS distinct_values_normalised
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL
  GROUP BY 1, 2, 3
),
j AS (
  SELECT t.*, COALESCE(r.refs, 0) AS refs, COALESCE(r.distinct_values, 0) AS distinct_values,
         COALESCE(r.distinct_values, 0) - COALESCE(r.distinct_values_normalised, 0) AS value_variants,
         COUNT(*) OVER (PARTITION BY t.name_key) - 1 AS lookalike_tags
  FROM t
  LEFT JOIN r ON r.tag_database = UPPER(t.tag_database) AND r.tag_schema = UPPER(t.tag_schema)
             AND r.tag_name = UPPER(t.tag_name)
),
s AS (
  SELECT j.*, refs = 0 AND created < DATEADD(day, -:grace_days, __AS_OF_DATE__) AS unused,
         NOT has_allowed_values AND distinct_values >= :free_values AS free_form
  FROM j
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, tag_database || '.' || tag_schema || '.' || tag_name AS tag_name,
       tag_id, tag_database, tag_schema, tag_owner, created, has_allowed_values, refs AS tag_references, distinct_values,
       value_variants, lookalike_tags,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(unused, 'no references', NULL),
         IFF(lookalike_tags > 0, lookalike_tags || ' look-alike tag names', NULL),
         IFF(value_variants > 0, value_variants || ' values differ only in case or spaces', NULL),
         IFF(free_form, distinct_values || ' distinct values and no allowed list', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE WHEN unused OR lookalike_tags > 0 OR value_variants > 0 OR free_form THEN 'WARN' ELSE 'OK' END AS status
FROM s
ORDER BY CASE WHEN unused OR lookalike_tags > 0 OR value_variants > 0 OR free_form THEN 0 ELSE 1 END, tag_references DESC, tag_name
