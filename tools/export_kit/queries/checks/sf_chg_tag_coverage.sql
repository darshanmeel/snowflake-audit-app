-- query_id: sf_chg_tag_coverage
-- title: Spending warehouses, databases, users and roles with no cost tag
-- domain: cost   tier: standard
-- entity: objects = object_type, object_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 50) usd: at or above this the row reads WARN; :crit_usd (default 500) usd:
--   at or above this the row reads CRITICAL; :warn_share_pct (default 30) share pct: at or above this
--   the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- money: est_usd_list
-- read_this: one row = one warehouse, database, user or role that spent credits in the window.
--   Warehouses carry their metered credits (compute + cloud services); users and roles their exact
--   attributed query credits; databases the attributed credits of queries run in them. cost_tag_* shows
--   the cost-center-like object tag set directly on the object (none = untagged).
--   tagged_share_of_type_pct is the part of that object type's spend that sits on tagged objects, i.e.
--   how much can be charged back by tag today.
--   basis (warehouse, user, role, database) names the allocation the row belongs to; compare rows of one
--   basis only.
-- healthy: status = OK when the object carries a cost tag or spends little.
-- investigate_if: WARN when an untagged object spends >= warn_usd, or is by itself >= warn_share_pct of
--   its object type's spend; CRITICAL when an untagged object spends >= crit_usd.
-- actions: 1) agree one tag (e.g. COST_CENTER) with allowed values and a tag owner (free); 2) ALTER
--   WAREHOUSE/DATABASE/USER/ROLE ... SET TAG on the top untagged rows (config); 3) block new untagged
--   warehouses with a creation process or a check in CI (config).
-- next: none
-- caveats: only direct tag references count (warehouse, user and role tags are not inherited). Tags are
--   matched by name pattern (COST_CENTER, CHARGEBACK, BUSINESS_UNIT, DEPARTMENT, TEAM, OWNER, PROJECT).
--   TAG_REFERENCES lags up to 2 hours; attribution up to 8 hours. The four object types overlap (the
--   same credit shows under a warehouse, a user, a role and a database); is_alt_basis marks the
--   user, role and database rows, so the $ figure counts the warehouse rows only.
WITH -- Exact per-query compute credits (QUERY_ATTRIBUTION_HISTORY) with the query's context from
-- QUERY_HISTORY, which the attribution view does not carry (role, database, schema, session, type).
-- QUERY_HISTORY is read one extra day back so a query started just before the window still joins.
-- The join is outer: a query with no QUERY_HISTORY row keeps its credits, with the user, warehouse and
-- tag the attribution view carries itself and '(no query history row)' for the rest.
sf_chg_attr AS (
  SELECT query_id,
         SUM(credits_attributed_compute) AS credits,
         SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits,
         MAX(user_name) AS user_name, MAX(warehouse_name) AS warehouse_name,
         MAX(warehouse_id) AS warehouse_id, MAX(query_tag) AS query_tag, MIN(start_time) AS start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY query_id
),
sf_chg_query_credits AS (
  SELECT a.query_id, COALESCE(q.start_time, a.start_time) AS start_time,
         COALESCE(NULLIF(TRIM(COALESCE(q.user_name, a.user_name)), ''), '(unknown user)') AS user_name,
         IFF(q.query_id IS NULL, '(no query history row)', q.role_name) AS role_name,
         IFF(q.query_id IS NULL, '(no query history row)', q.database_name) AS database_name, q.database_id,
         IFF(q.query_id IS NULL, '(no query history row)', q.schema_name) AS schema_name, q.schema_id,
         COALESCE(q.warehouse_name, a.warehouse_name) AS warehouse_name,
         TO_VARCHAR(COALESCE(q.warehouse_id, a.warehouse_id)) AS warehouse_id,
         COALESCE(q.query_tag, a.query_tag) AS query_tag, q.session_id, q.query_type, a.credits, a.qas_credits
  FROM sf_chg_attr a
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    ON q.query_id = a.query_id
   AND q.start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__)
   AND q.start_time < __AS_OF_DATE__
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
-- The one cost-owner tag per live warehouse, database, user and role, from direct tag references.
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
spend AS (
  SELECT 'WAREHOUSE' AS object_type, warehouse_name AS object_name, SUM((credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1))) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY warehouse_name
  UNION ALL
  SELECT 'USER', user_name, SUM(credits) FROM sf_chg_query_credits GROUP BY user_name
  UNION ALL
  SELECT 'ROLE', role_name, SUM(credits) FROM sf_chg_query_credits WHERE role_name IS NOT NULL GROUP BY role_name
  UNION ALL
  SELECT 'DATABASE', database_name, SUM(credits) FROM sf_chg_query_credits
  WHERE database_name IS NOT NULL GROUP BY database_name
),
s AS (
  SELECT sp.object_type, sp.object_name, sp.credits, t.tag_fqn AS cost_tag_name, t.tag_value AS cost_tag_value,
         t.tag_value IS NOT NULL AS is_tagged,
         100 * SUM(IFF(t.tag_value IS NOT NULL, sp.credits, 0)) OVER (PARTITION BY sp.object_type)
           / NULLIF(SUM(sp.credits) OVER (PARTITION BY sp.object_type), 0) AS tagged_share_of_type_pct,
         100 * sp.credits / NULLIF(SUM(sp.credits) OVER (PARTITION BY sp.object_type), 0) AS share_of_type_pct,
         (SELECT COUNT(*) FROM sf_chg_cost_tags) AS cost_tagged_objects_in_account
  FROM spend sp
  LEFT JOIN sf_chg_cost_tags t ON t.domain = sp.object_type AND t.object_name = UPPER(sp.object_name)
  WHERE sp.credits > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, object_type, object_name,
       is_tagged, cost_tag_name, cost_tag_value, credits, share_of_type_pct, tagged_share_of_type_pct,
       cost_tagged_objects_in_account,
       credits * __CREDIT_PRICE__ AS est_usd_list,
       object_type <> 'WAREHOUSE' AS is_alt_basis,
       -- one object type per chart: the four types overlap, so their bars never share one list
       LOWER(object_type) AS basis,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN is_tagged THEN 'OK'
         WHEN credits * __CREDIT_PRICE__ >= :crit_usd THEN 'CRITICAL'
         WHEN credits * __CREDIT_PRICE__ >= :warn_usd THEN 'WARN'
         WHEN share_of_type_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY object_type, is_tagged, credits DESC
