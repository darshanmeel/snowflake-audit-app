-- query_id: sf_storage_stage_bytes
-- shims: STAGE_STORAGE_USAGE_HISTORY, STORAGE_USAGE, STAGES
-- reads: INFORMATION_SCHEMA table functions STAGE_STORAGE_USAGE_HISTORY, DATABASE_STORAGE_USAGE_HISTORY, STAGES (view, per database)
-- fallback_note: stage storage for 6 months at most; storage for 6 months at most; no hybrid table or archive storage; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids
-- needs: MONITOR USAGE
WITH s AS (
  SELECT usage_date, COALESCE(average_stage_bytes, 0) AS stage_bytes
  FROM __SHIM_STAGE_STORAGE_USAGE_HISTORY__
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
su AS (
  SELECT MAX_BY(COALESCE(storage_bytes, 0) + COALESCE(stage_bytes, 0) + COALESCE(failsafe_bytes, 0), usage_date) AS end_total_bytes
  FROM __SHIM_STORAGE_USAGE__
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
  FROM __SHIM_STAGES__
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
