-- query_id: sf_storage_stale_stage_files
-- title: Internal stage files nobody cleaned up, per stage
-- domain: storage   tier: standard
-- entity: stages = stage_type, stage_full_name
-- windowed: no
-- money: est_saving_usd_month
-- reads: SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_DETAILS, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; an AWS or Azure account (the view is not supported
--   on GCP)
-- params: :stale_days (default 60) days: a stage whose newest file is older than this is stale;
--   :warn_usd_month (default 5) usd per month: a flagged stage at or above this reads WARN;
--   :crit_usd_month (default 100) usd per month: a flagged stage at or above this reads CRITICAL
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That a user stage lists the user id in ENTITY_ID is taken
--   from the column description. On GCP the view is not supported; whether it is absent or empty there is not
--   stated, so both read as not assessed.
-- read_this: one row = one internal stage (named, table or user) with bytes on its latest day. finding is
--   orphaned (the stage, its schema or its database is dropped but bytes remain), owner_gone (a user stage
--   of a disabled or deleted user), stale (no file changed in stale_days) or ok. est_storage_usd_month is
--   the stage's storage run-rate; est_saving_usd_month is the same figure on a flagged stage only.
-- healthy: status = OK when the stage was written to recently, or holds too little to matter.
-- investigate_if: WARN when a stale or owner-gone stage costs at least warn_usd_month, or a stage is orphaned;
--   CRITICAL when a flagged stage costs at least crit_usd_month.
-- actions: 1) LIST @stage and look at the newest files (free); 2) REMOVE files already loaded, or drop the
--   stage (config); 3) load with PURGE = TRUE and clean the user or table stages of leavers (engineering).
-- next: sf_storage_stage_bytes
-- caveats: The view lags up to 2 days, keeps 90 days and is best effort with some days missing: a stage
--   counts if it has a row within 2 days of the latest day; older than that it is taken as emptied. The
--   latest day is the one cut-off for bytes and age. Stale means no file changed, not that no one reads
--   the stage. User stages are matched to USERS by user id (name only when the id finds none); a user not
--   listed at all (deleted over a year ago) reads owner_state not_listed and is flagged. An orphaned stage
--   may still be inside the retention that allows UNDROP of its schema or database; Snowflake purges its
--   files afterwards. The account total and share of storage stay on the stage bytes check. Not
--   supported on GCP: the check reads not assessed there.
WITH d AS (
  SELECT stage_type, entity_id, usage_date, catalog_name, schema_name, entity_name, bytes, file_count,
         stage_dropped, catalog_dropped, schema_dropped, max_last_modified, min_last_modified
  FROM SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_DETAILS
  WHERE usage_date < __AS_OF_DATE__
),
g AS (
  SELECT MAX(usage_date) AS latest_day FROM d
),
l AS (
  SELECT d.stage_type, TO_VARCHAR(d.entity_id) AS stage_id,
         MAX_BY(d.catalog_name, d.usage_date) AS database_name, MAX_BY(d.schema_name, d.usage_date) AS schema_name,
         MAX_BY(d.entity_name, d.usage_date) AS entity_name, MAX_BY(d.bytes, d.usage_date) AS bytes,
         MAX_BY(d.file_count, d.usage_date) AS file_count,
         MAX_BY(d.max_last_modified, d.usage_date) AS newest_file_at,
         MAX_BY(d.min_last_modified, d.usage_date) AS oldest_file_at,
         MAX_BY(d.stage_dropped, d.usage_date) AS stage_dropped,
         MAX_BY(d.catalog_dropped, d.usage_date) AS catalog_dropped,
         MAX_BY(d.schema_dropped, d.usage_date) AS schema_dropped,
         MAX(d.usage_date) AS last_day
  FROM d
  GROUP BY 1, 2
),
ui AS (
  SELECT TO_VARCHAR(user_id) AS user_key, COUNT(*) AS listed,
         COUNT_IF(deleted_on IS NULL AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)) AS live,
         COUNT_IF(deleted_on IS NULL) AS not_deleted
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  GROUP BY 1
),
un AS (
  SELECT UPPER(name) AS name_key, COUNT(*) AS listed,
         COUNT_IF(deleted_on IS NULL AND NOT COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)) AS live,
         COUNT_IF(deleted_on IS NULL) AS not_deleted
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  GROUP BY 1
),
j AS (
  SELECT l.*, g.latest_day,
         IFF(l.stage_type = 'User', l.entity_name,
             l.database_name || '.' || l.schema_name || '.' || l.entity_name) AS stage_full_name,
         DATEDIFF('day', l.newest_file_at, g.latest_day) AS newest_file_age_days,
         l.bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS storage_usd,
         (l.stage_dropped IS NOT NULL OR l.schema_dropped IS NOT NULL OR l.catalog_dropped IS NOT NULL) AS is_orphaned,
         CASE WHEN l.stage_type <> 'User' THEN NULL
              WHEN COALESCE(ui.listed, un.listed, 0) = 0 THEN 'not_listed'
              WHEN COALESCE(ui.not_deleted, un.not_deleted) = 0 THEN 'deleted'
              WHEN COALESCE(ui.live, un.live) = 0 THEN 'disabled'
              ELSE 'active' END AS owner_state
  FROM l CROSS JOIN g
  LEFT JOIN ui ON l.stage_type = 'User' AND ui.user_key = l.stage_id
  LEFT JOIN un ON l.stage_type = 'User' AND ui.user_key IS NULL AND un.name_key = UPPER(l.entity_name)
  -- The view misses some days, so a stage seen within 2 days of the latest day is live; an older last row is an emptied stage.
  WHERE l.last_day >= DATEADD(day, -2, g.latest_day) AND COALESCE(l.bytes, 0) > 0
),
s AS (
  SELECT j.*, COALESCE(owner_state IN ('not_listed', 'deleted', 'disabled'), FALSE) AS owner_gone,
         COALESCE(newest_file_age_days >= :stale_days, FALSE) AS is_stale
  FROM j
),
f AS (
  SELECT s.*,
         CASE WHEN is_orphaned THEN 'orphaned' WHEN owner_gone THEN 'owner_gone' WHEN is_stale THEN 'stale'
              ELSE 'ok' END AS finding
  FROM s
),
main AS (
  SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, stage_type, stage_full_name, stage_id, database_name,
         schema_name, latest_day AS as_of_day, bytes, bytes / POWER(1024, 3) AS stage_gb, file_count, newest_file_at,
         oldest_file_at, newest_file_age_days, owner_state, finding,
         storage_usd AS est_storage_usd_month,
         IFF(finding <> 'ok', storage_usd, NULL) AS est_saving_usd_month,
         IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
         ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           IFF(is_orphaned, 'stage or its schema or database is dropped, ' || ROUND(bytes / POWER(1024, 3), 1) || ' GB remain', NULL),
           IFF(owner_gone, 'user stage of a ' || owner_state || ' user', NULL),
           IFF(is_stale, 'newest file ' || newest_file_age_days || ' days old', NULL)), '; ') AS reasons,
         CAST(NULL AS VARCHAR) AS not_assessed_reason,
         CASE
           WHEN finding = 'ok' THEN 'OK'
           WHEN storage_usd >= :crit_usd_month THEN 'CRITICAL'
           WHEN is_orphaned OR storage_usd IS NULL OR storage_usd >= :warn_usd_month THEN 'WARN'
           ELSE 'OK'
         END AS status
  FROM f
)
SELECT * FROM main
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
         est_saving_usd_month DESC NULLS LAST, stage_full_name
