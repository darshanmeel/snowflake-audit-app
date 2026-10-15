-- query_id: sf_storage_growth_by_database
-- title: Database storage growth
-- domain: storage   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_usd (default 10) usd: least a row needs before it can flag; :warn_growth_pct (default
--   20) growth pct: at or above this the row reads WARN; :crit_growth_pct (default 50) growth pct: at
--   or above this the row reads CRITICAL; :crit_added_usd (default 100) added usd: at or above this the
--   row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = a database. start_bytes and end_bytes are the daily average (database plus
--   Fail-safe bytes) on the first and last day of the window it has data for; growth_pct is the change.
--   est_storage_usd_month prices end_bytes; projected_usd_month_in_30d extends the window's daily
--   growth for 30 more days. Dropped databases still billed show dropped_at.
-- healthy: status = OK when the database costs under min_usd a month or grew less than warn_growth_pct
--   over the window.
-- investigate_if: WARN when it grew warn_growth_pct or more, or grew from empty; the SQL marks it
--   CRITICAL when it grew crit_growth_pct or more, or the next 30 days at this pace add crit_added_usd a
--   month, but the app shows a trend report as WARN at most.
-- actions: 1) open sf_storage_time_travel_heavy, sf_storage_failsafe_on_staging and
--   sf_storage_unused_tables for this database to see which tables grew (free); 2) lower retention or
--   make rebuildable data transient (config); 3) add retention/purge jobs for append-only history
--   tables, or unload cold partitions (engineering).
-- next: none
-- caveats: daily averages lag up to 3 hours; a new database with one day of data has no growth. Hybrid
--   table and archive storage are not included. Linear projection only.
WITH d AS (
  SELECT database_id, database_name, usage_date, deleted,
         COALESCE(average_database_bytes, 0) + COALESCE(average_failsafe_bytes, 0) AS bytes,
         COALESCE(average_failsafe_bytes, 0) AS failsafe_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
g AS (
  SELECT database_id, MAX_BY(database_name, usage_date) AS database_name, MAX(deleted) AS dropped_at,
         MIN(usage_date) AS first_day, MAX(usage_date) AS last_day, COUNT(*) AS days_seen,
         MIN_BY(bytes, usage_date) AS start_bytes, MAX_BY(bytes, usage_date) AS end_bytes,
         MAX_BY(failsafe_bytes, usage_date) AS end_failsafe_bytes, MAX(bytes) AS peak_bytes
  FROM d
  GROUP BY database_id
),
t AS (
  SELECT g.*,
         end_bytes - start_bytes AS growth_bytes,
         100 * (end_bytes - start_bytes) / NULLIF(start_bytes, 0) AS growth_pct,
         (end_bytes - start_bytes) / NULLIF(DATEDIFF(day, first_day, last_day), 0) AS bytes_per_day,
         end_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS usd
  FROM g
),
p AS (
  SELECT t.*,
         GREATEST(end_bytes + 30 * COALESCE(bytes_per_day, 0), 0) / POWER(1024, 4)
           * __STORAGE_PRICE_TB_MONTH__ AS projected_usd
  FROM t
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       database_name, database_id, dropped_at, first_day, last_day, days_seen,
       start_bytes, end_bytes, end_failsafe_bytes, peak_bytes, growth_bytes,
       ROUND(growth_pct, 1) AS growth_pct, bytes_per_day,
       end_bytes / POWER(1024, 4) AS end_tb,
       usd AS est_storage_usd_month,
       projected_usd AS projected_usd_month_in_30d,
       projected_usd - usd AS projected_added_usd_month,
       IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(growth_bytes / POWER(1024, 3), 1) || ' GB change ('
         || COALESCE(ROUND(growth_pct) || '%', 'new') || ') over ' || days_seen || ' days' AS waste_reason,
       CASE WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced'
            WHEN days_seen < 2 THEN 'too_little_history' END AS not_assessed_reason,
       CASE
         WHEN __STORAGE_PRICE_TB_MONTH__ IS NULL OR days_seen < 2 THEN 'NOT_ASSESSED'
         WHEN usd < :min_usd AND projected_usd < :min_usd THEN 'OK'
         -- a database that started empty has no growth_pct; growth from zero counts as growth at crit
         WHEN COALESCE(growth_pct, IFF(end_bytes > 0, :crit_growth_pct, 0)) >= :crit_growth_pct
              OR projected_usd - usd >= :crit_added_usd THEN 'CRITICAL'
         WHEN growth_pct >= :warn_growth_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM p
ORDER BY growth_bytes DESC NULLS LAST
