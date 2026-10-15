-- query_id: access_tags_inventory
-- title: Manual governance tags inventory
-- domain: governance_access   tier: standard
-- entity: tags = object_scope, tag_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a tag name/value pair at column, table, schema or database scope, with how
--   many objects carry it. Use it to see your account's actual tagging vocabulary in practice.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: none
-- caveats: Snowflake version: object_scope = the tagged object's domain (COLUMN, TABLE, SCHEMA,
--   DATABASE, WAREHOUSE, USER, ...); tag_name without its database and schema. Live objects only.
SELECT 0 AS window_days, domain AS object_scope, tag_name, tag_value,
       COUNT(*) AS tagged_object_count
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE object_deleted IS NULL
GROUP BY domain, tag_name, tag_value
ORDER BY object_scope, tag_name, tag_value
