-- The one cost-owner tag per live warehouse, database, user and role, from direct tag references.
-- Tag names are free text, so cost-center-like names are matched by pattern; when an object has
-- several, a COST_CENTER-style name wins over CHARGEBACK/BUSINESS_UNIT/DEPARTMENT, then TEAM/OWNER/PROJECT.
sf_chg_cost_tags AS (
  SELECT domain, UPPER(object_name) AS object_name, object_id,
         tag_database || '.' || tag_schema || '.' || tag_name AS tag_fqn,
         tag_name, tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL
    AND domain IN ('WAREHOUSE', 'DATABASE', 'USER', 'ROLE')
    AND REGEXP_LIKE(UPPER(tag_name),
          '.*(COST_?CENT(ER|RE)|CHARGE_?BACK|BUSINESS_?UNIT|DEPARTMENT|TEAM|OWNER|PROJECT).*')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY domain, UPPER(object_name)
    ORDER BY CASE WHEN REGEXP_LIKE(UPPER(tag_name), '.*COST_?CENT(ER|RE).*') THEN 1
                  WHEN REGEXP_LIKE(UPPER(tag_name), '.*(CHARGE_?BACK|BUSINESS_?UNIT|DEPARTMENT).*') THEN 2
                  ELSE 3 END,
             tag_name) = 1
)
