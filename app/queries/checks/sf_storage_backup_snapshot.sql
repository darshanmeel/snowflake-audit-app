-- query_id: sf_storage_backup_snapshot
-- title: Backup and snapshot storage by backup set
-- domain: storage   tier: standard
-- entity: backup sets = set_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.BACKUP_STORAGE_USAGE, SNOWFLAKE.ACCOUNT_USAGE.BACKUP_SETS,
--   SNOWFLAKE.ACCOUNT_USAGE.SNAPSHOT_STORAGE_USAGE, SNOWFLAKE.ACCOUNT_USAGE.SNAPSHOT_SETS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :min_usd_month (default 5) usd per month: least a set needs before it can flag; :crit_usd_month
--   (default 500) usd per month: a flagged set costing this much reads CRITICAL
-- empty_if: no_activity, view_missing
-- not_assessed_reasons: unpriced: no storage price is available, so the storage cannot be priced
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The upper-bound size is derived from the documented columns.
-- read_this: one row = one backup set (or one deprecated snapshot set). backups counts its backups,
--   largest_backup_bytes the biggest one restored, added_bytes the data each backup added to the one before.
--   retained_bytes_upper = smallest backup + all bytes added and removed between backups, an upper bound
--   for the storage the set holds (files are shared between backups, so the true figure is lower). est_storage_usd_month prices that
--   at the storage price per TB per month. policy_name is empty for a set no policy expires.
-- healthy: status = OK when a backup policy expires the set's backups.
-- investigate_if: WARN when a set with no policy, or any snapshot set, holds at least :min_usd_month;
--   CRITICAL at :crit_usd_month.
-- actions: 1) attach a backup policy with an expiry to the sets nothing expires (config); 2) drop sets for
--   objects that no longer exist (free); 3) move snapshot sets to backup sets, as snapshots are deprecated
--   (config)
-- next: sf_storage_retention_policy
-- caveats: Neither usage view has a date, so this is what the sets hold now. The estimate is an upper bound
--   and the saving from dropping one backup is smaller. Backup and snapshot storage is billed as storage; it is
--   not in the Time Travel or Fail-safe figures. A deleted set can still hold backups until they expire. The
--   monthly figure is a run-rate, never added to window spend.
WITH b AS (
  SELECT 'backup' AS set_kind, u.backup_set_id AS set_id, COUNT(*) AS backups, MAX(u.logical_bytes) AS largest_backup_bytes,
         MIN(u.logical_bytes) AS smallest_backup_bytes, SUM(u.incremental_bytes_from_previous_backup) AS added_bytes,
         SUM(u.decremental_bytes_from_previous_backup) AS removed_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.BACKUP_STORAGE_USAGE u
  GROUP BY u.backup_set_id
  UNION ALL
  SELECT 'snapshot', u.snapshot_set_id, COUNT(*), MAX(u.logical_bytes), MIN(u.logical_bytes),
         SUM(u.incremental_bytes_from_previous_snapshot), SUM(u.decremental_bytes_from_previous_snapshot)
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNAPSHOT_STORAGE_USAGE u
  GROUP BY u.snapshot_set_id
),
sets AS (
  SELECT 'backup' AS set_kind, s.id AS set_id, s.name AS set_name, s.catalog_name, s.schema_name, s.object_kind,
         s.object_name, s.backup_policy_name AS policy_name, s.deleted
  FROM SNOWFLAKE.ACCOUNT_USAGE.BACKUP_SETS s
  UNION ALL
  SELECT 'snapshot', s.id, s.name, s.catalog_name, s.schema_name, s.object_kind, s.object_name,
         s.snapshot_policy_name, s.deleted
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNAPSHOT_SETS s
),
j AS (
  SELECT b.set_kind, b.set_id, b.backups, b.largest_backup_bytes, b.added_bytes,
         -- the largest backup already holds the growth; any backup plus every change since covers the set
         COALESCE(b.smallest_backup_bytes, 0) + COALESCE(b.added_bytes, 0) + COALESCE(b.removed_bytes, 0)
           AS retained_bytes_upper,
         COALESCE(s.catalog_name || '.' || s.schema_name || '.' || s.set_name, '(set ' || b.set_id || ' not listed)') AS set_name,
         s.object_kind, s.object_name, s.policy_name, s.deleted IS NOT NULL AS set_deleted
  FROM b
  LEFT JOIN sets s ON s.set_kind = b.set_kind AND s.set_id = b.set_id
),
x AS (
  SELECT j.*, retained_bytes_upper / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS usd_month,
         (set_kind = 'snapshot' OR (policy_name IS NULL AND set_name NOT LIKE '(set %')) AS unmanaged
  FROM j
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, set_kind, set_name, set_id, object_kind, object_name, policy_name,
       set_deleted, backups, largest_backup_bytes, added_bytes, retained_bytes_upper,
       usd_month AS est_storage_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(set_kind = 'snapshot', 'snapshots are deprecated', NULL),
         IFF(set_kind = 'backup' AND policy_name IS NULL AND unmanaged, 'no backup policy expires it', NULL),
         IFF(set_deleted, 'set was deleted but still holds backups', NULL)), '; ') AS reasons,
       CASE WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN unmanaged AND usd_month >= :crit_usd_month THEN 'CRITICAL'
         WHEN unmanaged AND usd_month >= :min_usd_month THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM x
ORDER BY est_storage_usd_month DESC NULLS LAST, set_name
