-- query_id: sf_storage_growth_by_database
-- reads: INFORMATION_SCHEMA.DATABASE_STORAGE_USAGE_HISTORY (table function)
-- needs: MONITOR USAGE
-- fallback_note: the database name stands in for its id; no drop dates
-- Same columns as checks/sf_storage_growth_by_database.sql. The table function keeps 6 months and has
-- no database id or drop date: a dropped database past retention shows as DROPPED__<id>.
WITH d AS (
  SELECT database_name AS database_id, database_name, usage_date, CAST(NULL AS TIMESTAMP_LTZ) AS deleted,
         COALESCE(average_database_bytes, 0) + COALESCE(average_failsafe_bytes, 0) AS bytes,
         COALESCE(average_failsafe_bytes, 0) AS failsafe_bytes
  FROM TABLE(__INFO_SCHEMA__.DATABASE_STORAGE_USAGE_HISTORY(
         DATE_RANGE_START => GREATEST(DATEADD(day, -:period_days, __AS_OF_DATE__), DATEADD(day, 1, DATEADD(month, -6, CURRENT_DATE()))),
         DATE_RANGE_END => LEAST(__AS_OF_DATE__, CURRENT_DATE())))
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
