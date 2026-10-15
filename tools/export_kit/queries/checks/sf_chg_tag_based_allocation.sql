-- query_id: sf_chg_tag_based_allocation
-- title: Spend allocated by warehouse tag and by user tag
-- domain: cost   tier: standard
-- entity: tag values = basis, tag_value
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_untagged_pct (default 20) untagged pct: at or above this the row reads WARN;
--   :crit_untagged_pct (default 50) untagged pct: at or above this the row reads CRITICAL;
--   :min_spend_usd (default 100) spend usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- money: est_usd_list
-- read_this: one row = one cost tag value under one allocation basis. basis 'warehouse_tag' splits all
--   metered warehouse credits (compute + cloud services) by the cost tag on the warehouse; basis
--   'user_tag' splits exact attributed query credits by the cost tag on the user who ran the query,
--   with a '(warehouse idle)' row for compute nobody ran; a query with no user name is the untagged
--   object '(unknown user)'. Query acceleration is billed as its own service and is not in either basis. '(untagged)' is spend with no tag under that
--   basis. share_of_basis_pct rows add up to 100 per basis. tag_names lists the tag(s) the values came
--   from; the preferred name is COST_CENTER-like, then CHARGEBACK/BUSINESS_UNIT/DEPARTMENT, then
--   TEAM/OWNER/PROJECT. The two bases are two views of the same credits: is_alt_basis marks the
--   user_tag rows, so the $ figure counts the warehouse_tag basis only.
-- healthy: status = OK when little spend is left untagged under a basis.
-- investigate_if: WARN when '(untagged)' is >= warn_untagged_pct of a basis (and >= min_spend_usd);
--   CRITICAL at crit_untagged_pct.
-- actions: 1) pick the basis that fits how teams work: shared warehouses -> user tag, one warehouse per
--   team -> warehouse tag (free); 2) tag the largest untagged warehouses and users (see
--   sf_chg_tag_coverage) (config); 3) split shared warehouses per cost center where user tags cannot be
--   kept up to date (config).
-- next: none
-- caveats: adaptive warehouses (no query-time split) and hours newer than the 8 h attribution lag are left out of both sides, so they never read as idle; the tag is matched by name pattern because check parameters are numeric; if several
--   cost-like tags exist the preferred one per object wins. Current tag values are applied to the whole
--   window. Queries under about 100 ms have no attribution row and land in '(warehouse idle)'.
WITH -- The one cost-owner tag per live warehouse, database, user and role, from direct tag references.
-- Tag names are free text, so cost-center-like names are matched by pattern; when an object has
-- several, a COST_CENTER-style name wins over CHARGEBACK/BUSINESS_UNIT/DEPARTMENT, then TEAM/OWNER/PROJECT.
sf_chg_cost_tags AS (
  SELECT domain, UPPER(object_name) AS object_name, object_id,
         tag_database || '.' || tag_schema || '.' || tag_name AS tag_fqn,
         tag_name, tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL
    AND domain IN ('WAREHOUSE', 'DATABASE', 'USER', 'ROLE')
    AND REGEXP_LIKE(UPPER(tag_name),
          '.*(COST_?CENT(ER|RE)|CHARGE_?BACK|BUSINESS_?UNIT|DEPARTMENT|TEAM|OWNER|PROJECT).*')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY domain, UPPER(object_name)
    ORDER BY CASE WHEN REGEXP_LIKE(UPPER(tag_name), '.*COST_?CENT(ER|RE).*') THEN 1
                  WHEN REGEXP_LIKE(UPPER(tag_name), '.*(CHARGE_?BACK|BUSINESS_?UNIT|DEPARTMENT).*') THEN 2
                  ELSE 3 END,
             tag_name) = 1
),
-- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
wh AS (
  SELECT warehouse_name, SUM((credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1))) AS credits, SUM(IFF(credits_attributed_compute_queries IS NOT NULL AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_used_compute, 0)) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY warehouse_name
),
us AS (
  SELECT COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)') AS user_name, SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP())
  GROUP BY COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)')
),
alloc AS (
  SELECT 'warehouse_tag' AS basis, COALESCE(t.tag_value, '(untagged)') AS tag_value, t.tag_fqn,
         wh.warehouse_name AS object_name, wh.credits
  FROM wh
  LEFT JOIN sf_chg_cost_tags t ON t.domain = 'WAREHOUSE' AND t.object_name = UPPER(wh.warehouse_name)
  UNION ALL
  SELECT 'user_tag', COALESCE(t.tag_value, '(untagged)'), t.tag_fqn, us.user_name, us.credits
  FROM us
  LEFT JOIN sf_chg_cost_tags t ON t.domain = 'USER' AND t.object_name = UPPER(us.user_name)
  UNION ALL
  SELECT 'user_tag', '(warehouse idle)', NULL, NULL,
         GREATEST((SELECT SUM(compute_credits) FROM wh) - (SELECT COALESCE(SUM(credits), 0) FROM us), 0)
),
g AS (
  SELECT basis, tag_value,
         ARRAY_TO_STRING(ARRAY_AGG(DISTINCT tag_fqn), ', ') AS tag_names,
         COUNT(DISTINCT object_name) AS objects,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT object_name), 0, 10), ', ') AS sample_objects,
         SUM(credits) AS credits
  FROM alloc
  GROUP BY basis, tag_value
),
s AS (
  SELECT g.*, 100 * credits / NULLIF(SUM(credits) OVER (PARTITION BY basis), 0) AS share_pct
  FROM g
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, basis, tag_value, tag_names,
       objects, sample_objects, credits, share_pct AS share_of_basis_pct,
       credits * __CREDIT_PRICE__ AS est_usd_list,
       basis = 'user_tag' AS is_alt_basis,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN tag_value <> '(untagged)' OR credits * __CREDIT_PRICE__ < :min_spend_usd THEN 'OK'
         WHEN share_pct >= :crit_untagged_pct THEN 'CRITICAL'
         WHEN share_pct >= :warn_untagged_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
WHERE credits > 0
ORDER BY basis, credits DESC
