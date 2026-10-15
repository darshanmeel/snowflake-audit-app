-- windowed: no
-- Object tags (TAG_REFERENCES, direct assignments only): which tag value each warehouse, user, role,
-- task, table, schema, database and the account carries. Tag names and values only, never a policy
-- body or a column value. Deleted objects are left out.
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, UPPER(domain) AS domain,
       object_database, object_schema, object_name, tag_name, COALESCE(tag_value, '') AS tag_value,
       apply_method
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE object_deleted IS NULL
  AND UPPER(domain) IN ('ACCOUNT', 'DATABASE', 'SCHEMA', 'TABLE', 'WAREHOUSE', 'USER', 'ROLE', 'TASK')
  AND tag_name IS NOT NULL
