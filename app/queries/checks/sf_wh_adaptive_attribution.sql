-- query_id: sf_wh_adaptive_attribution
-- title: Adaptive warehouse spend by user, from the per-query hourly meter
-- domain: compute   tier: standard
-- entity: adaptive warehouses = warehouse_id
-- windowed: yes
-- money: est_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition or higher (adaptive warehouses)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_users (default 50) users: the most expensive users per warehouse are named, the rest read as
--   (other users); :warn_unattributed_pct (default 20) percent: an unattributed share of a warehouse at or
--   above this reads WARN; :min_usd (default 10) usd: least an unattributed remainder needs before it can flag
-- empty_if: no_activity, edition_too_low, view_missing
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be priced
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account with an adaptive warehouse. That QUERY_METERING_HISTORY holds
--   adaptive warehouses only is from its documentation.
-- read_this: one row = one user on one adaptive warehouse plus one remainder row per
--   warehouse for unowned credits (row_kind user or unattributed). est_usd_list is
--   compute plus billed cloud services (after the daily 10% adjustment). The rows of a warehouse add up to
--   its billed spend, the same figure the chargeback by warehouse shows.
-- healthy: status = OK when the remainder is a small share of the warehouse's spend.
-- investigate_if: WARN when the unattributed remainder of a warehouse is at or above :warn_unattributed_pct
--   percent and at least :min_usd.
-- actions: 1) hand each user's line to the team that owns them for chargeback (free); 2) tag queries with
--   QUERY_TAG so a team shows up without user names (config); 3) move heavy users to their own warehouse
--   when one user dominates (config)
-- next: sf_cost_query_attribution_by_user
-- caveats: The other attribution views are NULL on adaptive warehouses, so this is the only per-user
--   split for them. The hourly meter lags up to 1 hour, the warehouse meter up to 3. A query is billed
--   in every hour it runs, so one query can appear in several hours. The unattributed remainder is billed
--   minus attributed, never below zero.
WITH __INCLUDE_sf_cs_billed_ratio__,
wh AS (
  SELECT m.warehouse_id, m.warehouse_name,
         SUM(m.credits_used_compute + m.credits_used_cloud_services * COALESCE(r.billed_ratio, 1)) AS billed_credits,
         COUNT_IF(m.credits_attributed_compute_queries IS NULL
                  AND m.start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP())) AS unattributed_hours,
         COUNT_IF(m.credits_attributed_compute_queries IS NOT NULL) AS attributed_hours
         , SUM(m.credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(m.start_time)
  WHERE m.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND m.start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
q AS (
  SELECT h.warehouse_id, h.warehouse_name, COALESCE(h.user_name, '(unknown user)') AS user_name,
         SUM(h.credits_used_compute + h.credits_used_cloud_services * COALESCE(r.billed_ratio, 1)) AS credits,
         COUNT(DISTINCT h.query_id) AS queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_METERING_HISTORY h
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(h.query_metering_hour)
  WHERE h.query_metering_hour >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND h.query_metering_hour < __AS_OF_DATE__
  GROUP BY 1, 2, 3
),
ranked AS (
  SELECT q.*, ROW_NUMBER() OVER (PARTITION BY warehouse_id ORDER BY credits DESC, user_name) AS rn
  FROM q
),
users AS (
  SELECT warehouse_id, MAX(warehouse_name) AS warehouse_name,
         IFF(rn <= :top_users, user_name, '(other users)') AS user_name,
         SUM(credits) AS credits, SUM(queries) AS queries
  FROM ranked
  GROUP BY warehouse_id, IFF(rn <= :top_users, user_name, '(other users)')
),
ad AS (
  -- compute > 0 keeps out CLOUD_SERVICES_ONLY, whose attribution is NULL because it has no compute
  SELECT warehouse_id, warehouse_name FROM wh
  WHERE unattributed_hours > 0 AND attributed_hours = 0 AND compute_credits > 0
  UNION
  SELECT warehouse_id, MAX(warehouse_name) FROM q GROUP BY warehouse_id
),
attributed AS (
  SELECT warehouse_id, SUM(credits) AS attributed_credits FROM q GROUP BY warehouse_id
),
rows_ AS (
  SELECT u.warehouse_id, u.warehouse_name, 'user' AS row_kind, u.user_name, u.queries, u.credits,
         w.billed_credits AS warehouse_billed_credits
  FROM users u
  LEFT JOIN wh w ON w.warehouse_id = u.warehouse_id
  UNION ALL
  SELECT a.warehouse_id, a.warehouse_name, 'unattributed', '(not attributed)', CAST(NULL AS NUMBER),
         GREATEST(COALESCE(w.billed_credits, 0) - COALESCE(t.attributed_credits, 0), 0), w.billed_credits
  FROM ad a
  JOIN wh w ON w.warehouse_id = a.warehouse_id
  LEFT JOIN attributed t ON t.warehouse_id = a.warehouse_id
),
s AS (
  SELECT rows_.*, 100 * credits / NULLIF(warehouse_billed_credits, 0) AS share_pct,
         credits * __CREDIT_PRICE__ AS usd
  FROM rows_
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, row_kind, user_name,
       queries, credits, warehouse_billed_credits, share_pct, usd AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(row_kind = 'unattributed' AND share_pct >= :warn_unattributed_pct, 'billed credits not tied to a query: ' || ROUND(share_pct, 0) || '% of the warehouse', NULL) AS reasons,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN row_kind = 'unattributed' AND share_pct >= :warn_unattributed_pct AND usd >= :min_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY warehouse_name, IFF(row_kind = 'user', 0, 1), credits DESC
