-- query_id: sf_lin_declared_links
-- title: Every declared lineage link: which object is built on which
-- domain: governance_access   tier: standard
-- entity: lineage links = source_fqn, target_fqn
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (OBJECT_VIEWER)
-- params: none
-- empty_if: role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one object (target_fqn) built on another (source_fqn), as Snowflake records it. The
--   Lineage explorer walks these links with sf_lin_copied_links to show everything upstream and downstream
--   of one table.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: sf_lin_copied_links
-- caveats: covers views, materialized views, dynamic tables and functions, not a table loaded by a task or
--   a tool; sf_lin_copied_links has those. Shows only objects the role can see and lags up to 3 hours. On a
--   very large account the export row cap can cut this list.
SELECT DISTINCT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       UPPER(referenced_database || '.' || referenced_schema || '.' || referenced_object_name) AS source_fqn,
       referenced_object_domain AS source_kind,
       UPPER(referencing_database || '.' || referencing_schema || '.' || referencing_object_name) AS target_fqn,
       referencing_object_domain AS target_kind
FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
WHERE referenced_object_name IS NOT NULL AND referencing_object_name IS NOT NULL
ORDER BY source_fqn, target_fqn
