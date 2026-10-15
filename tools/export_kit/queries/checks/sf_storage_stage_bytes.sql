-- query_id: sf_storage_stage_bytes
-- title: Files left in internal stages
-- domain: storage   tier: standard
-- entity: stage scopes = stage_scope
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE,
--   SNOWFLAKE.ACCOUNT_USAGE.STAGES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :stale_days (default 90) stale days: value this check uses; :warn_usd (default 10) usd: at or
--   above this the row reads WARN; :crit_usd (default 100) usd: at or above this the row reads
--   CRITICAL; :warn_share_pct (default 20) share pct: at or above this the row reads WARN;
--   :min_share_gb (default 10) share gb: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = the account's internal stage storage (named, user @~ and table @% stages
--   together). Per-stage bytes: sf_storage_stale_stage_files. end_stage_bytes is the last day of the window,
--   growth over the window shows whether loaded files are being cleaned up. stage_share_pct is stage
--   bytes over all billed storage. internal_named_stages / stale_named_stages count named internal
--   stages and those not altered in stale_days; stale_stage_names lists some of them.
-- healthy: status = OK when stages cost less than warn_usd a month and are under warn_share_pct of
--   storage.
-- investigate_if: WARN when stages cost warn_usd a month or more, or are warn_share_pct of storage or
--   more (and at least min_share_gb); CRITICAL at crit_usd a month.
-- actions: 1) LIST @stage (and @~, @%table) to see sizes and ages (free); 2) REMOVE files already
--   loaded, and use PURGE = TRUE on COPY INTO, or drop stale named stages (config); 3) keep raw files
--   in an external stage on your own cloud storage instead (engineering).
-- next: none
-- caveats: stage bytes are an account total; which stage holds them needs LIST. Daily values lag up to
--   3 hours. Stale means not altered, not unused: a stage can be read without being altered.
WITH s AS (
  SELECT usage_date, COALESCE(average_stage_bytes, 0) AS stage_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
su AS (
  SELECT MAX_BY(COALESCE(storage_bytes, 0) + COALESCE(stage_bytes, 0) + COALESCE(failsafe_bytes, 0), usage_date) AS end_total_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
g AS (
  SELECT COUNT(*) AS days_seen, MIN(usage_date) AS first_day, MAX(usage_date) AS last_day,
         MIN_BY(stage_bytes, usage_date) AS start_stage_bytes,
         MAX_BY(stage_bytes, usage_date) AS end_stage_bytes, MAX(stage_bytes) AS peak_stage_bytes
  FROM s
),
st AS (
  SELECT COUNT(*) AS internal_named_stages,
         COUNT_IF(COALESCE(last_altered, created) < DATEADD(day, -:stale_days, __AS_OF_DATE__))
           AS stale_named_stages,
         LEFT(LISTAGG(IFF(COALESCE(last_altered, created) < DATEADD(day, -:stale_days, __AS_OF_DATE__),
                          stage_catalog || '.' || stage_schema || '.' || stage_name, NULL), ', ')
                WITHIN GROUP (ORDER BY COALESCE(last_altered, created)), 1000) AS stale_stage_names
  FROM SNOWFLAKE.ACCOUNT_USAGE.STAGES
  WHERE deleted IS NULL AND stage_type ILIKE 'internal%'
),
t AS (
  SELECT g.*, st.*, su.end_total_bytes,
         100 * end_stage_bytes / NULLIF(su.end_total_bytes, 0) AS stage_share_pct,
         end_stage_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS usd
  FROM g CROSS JOIN st CROSS JOIN su
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       'ALL_INTERNAL_STAGES' AS stage_scope, first_day, last_day, days_seen,
       start_stage_bytes, end_stage_bytes, peak_stage_bytes,
       end_stage_bytes - start_stage_bytes AS growth_bytes,
       end_stage_bytes / POWER(1024, 3) AS end_stage_gb, end_total_bytes,
       ROUND(stage_share_pct, 1) AS stage_share_pct,
       internal_named_stages, stale_named_stages, stale_stage_names, :stale_days AS stale_days,
       usd AS est_storage_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(end_stage_bytes / POWER(1024, 3), 1) || ' GB in internal stages ('
         || COALESCE(ROUND(stage_share_pct) || '% of storage', 'share unknown') || ')' AS waste_reason,
       CASE WHEN days_seen = 0 THEN 'no_stage_history'
            WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN days_seen = 0 OR __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd OR (stage_share_pct >= :warn_share_pct
                                    AND end_stage_bytes >= :min_share_gb * POWER(1024, 3)) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
