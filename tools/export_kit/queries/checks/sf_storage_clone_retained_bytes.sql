-- query_id: sf_storage_clone_retained_bytes
-- title: Storage kept alive only by clones
-- domain: storage   tier: standard
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :min_gb (default 1) gb: least a row needs before it can flag; :warn_usd (default 10) usd: at
--   or above this the row reads WARN; :crit_usd (default 100) usd: at or above this the row reads
--   CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a table (live or dropped) whose deleted or overwritten data is still billed
--   because a clone points at it (retained_for_clone_bytes). The bytes go away only when every clone in
--   the same clone_group_id that still references them is dropped or rewrites that data.
--   clone_group_live_tables lists live tables in the group, i.e. the clones to look at.
-- healthy: status = OK when retained bytes cost less than warn_usd a month.
-- investigate_if: WARN when retained bytes cost warn_usd a month or more; CRITICAL at crit_usd, or when
--   the owning table is already dropped and still costs warn_usd a month.
-- actions: 1) find the clones in clone_group_live_tables and ask their owners if they are still needed
--   (free); 2) drop stale dev/test/backup clones, and keep backup clones on a short, dated rotation
--   (config); 3) refresh long-lived dev copies by re-cloning instead of keeping old clones.
-- next: none
-- caveats: a clone group also contains the source itself, so a live list can include the original
--   table. Bytes are point in time and lag up to 90 minutes.
WITH m AS (
  SELECT id AS table_id, table_catalog AS database_name, table_schema AS schema_name, table_name,
         -- Fail-safe rows have NULL names; label them by id so the row is never a bare id
         COALESCE(table_catalog || '.' || table_schema || '.' || table_name, 'Fail-safe table (' || id || ')')
           AS table_fqn, clone_group_id,
         COALESCE(active_bytes, 0) AS active_bytes,
         COALESCE(retained_for_clone_bytes, 0) AS retained_for_clone_bytes,
         -- Fail-safe rows can carry deleted = FALSE, so they would pass as live
         (COALESCE(deleted, FALSE) OR table_dropped IS NOT NULL OR table_entered_failsafe IS NOT NULL
          OR table_name IS NULL) AS is_dropped,
         table_created, table_dropped
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
),
grp AS (
  SELECT clone_group_id,
         COUNT_IF(NOT is_dropped) AS live_tables_in_group,
         LISTAGG(IFF(NOT is_dropped AND retained_for_clone_bytes = 0, table_fqn, NULL), ', ')
           WITHIN GROUP (ORDER BY table_fqn) AS clone_group_live_tables,
         MIN(IFF(NOT is_dropped, table_created, NULL)) AS oldest_live_member_created
  FROM m
  GROUP BY clone_group_id
),
t AS (
  SELECT m.*, g.live_tables_in_group, LEFT(g.clone_group_live_tables, 1000) AS clone_group_live_tables,
         g.oldest_live_member_created,
         retained_for_clone_bytes / POWER(1024, 3) AS retained_gb,
         retained_for_clone_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS retained_usd
  FROM m LEFT JOIN grp g ON g.clone_group_id = m.clone_group_id
  WHERE m.retained_for_clone_bytes >= :min_gb * POWER(1024, 3)
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, table_id, database_name, schema_name, table_name, clone_group_id, is_dropped,
       table_created, table_dropped, active_bytes, retained_for_clone_bytes, retained_gb,
       live_tables_in_group, clone_group_live_tables, oldest_live_member_created,
       retained_usd AS est_storage_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(retained_gb, 1) || ' GB kept for clones' || IFF(is_dropped, ' of a dropped table', '') AS waste_reason,
       CASE WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN retained_usd >= :crit_usd THEN 'CRITICAL'
         WHEN retained_usd >= :warn_usd AND is_dropped THEN 'CRITICAL'
         WHEN retained_usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY retained_for_clone_bytes DESC
