-- query_id: sf_cost_listing_auto_fulfillment
-- title: Listing auto-fulfillment: replication credits and storage by region and group
-- domain: cost   tier: standard
-- money: est_within_usd_list
-- entity: fulfillment groups = region_group, snowflake_region, fulfillment_group_name
-- windowed: yes
-- reads: SNOWFLAKE.DATA_SHARING_USAGE.LISTING_AUTO_FULFILLMENT_REFRESH_DAILY,
--   SNOWFLAKE.DATA_SHARING_USAGE.LISTING_AUTO_FULFILLMENT_DATABASE_STORAGE_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a provider account that publishes cross-region listings
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The views give credits per fulfillment group and region, not per
--   listing, so a group that serves several listings is not split between them.
-- read_this: one row = one fulfillment group in one remote region, plus a '(storage)' row per region for the bytes
--   the regional copies hold. listings_count is the
--   listings the group served in the window. current = the window, previous = the window before.
-- healthy: status = OK when a group's replication cost is small or flat.
-- investigate_if: WARN when a group spending >= min_spend_usd is new, grew >= warn_increase_pct or serves no listing;
--   CRITICAL when it grew >= crit_increase_pct.
-- actions: 1) check that each listing still has buyers in that region (free); 2) remove regions nobody
--   uses from the listing, or lengthen the refresh schedule (config); 3) stop fulfilling a listing that costs more than
--   it earns (spend)
-- next: sf_org_listing_auto_fulfillment
-- not_assessed_reasons: unpriced: no credit or storage price is available, so the row cannot be priced
-- caveats: replication credits are inside the account's metering totals, so this is a slice of spend, not an
--   addition to it. Storage is a monthly figure, kept apart from the credit cost,
--   averaged over every day of the window (a missing day counts as zero) and priced at this account's storage
--   rate, which can differ from the remote region's. The '(storage)' rows are marked is_alt_basis and are not
--   fulfillment groups. The views are for the provider
--   account, lag up to 2 days and are not for billing reconciliation. Stage storage is not included. Data
--   transfer for the refresh is in sf_cost_data_transfer_egress.
WITH r AS (
  SELECT region_group, snowflake_region, fulfillment_group_name,
         SUM(IFF(usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__), COALESCE(credits_used, 0), 0)) AS cur_credits,
         SUM(IFF(usage_date < DATEADD(day, -:period_days, __AS_OF_DATE__), COALESCE(credits_used, 0), 0)) AS prev_credits,
         SUM(IFF(usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__), COALESCE(bytes_transferred, 0), 0))
           / POWER(1024, 4) AS tb_transferred,
         COUNT(DISTINCT IFF(usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND COALESCE(credits_used, 0) > 0,
                            usage_date, NULL)) AS active_days
  FROM SNOWFLAKE.DATA_SHARING_USAGE.LISTING_AUTO_FULFILLMENT_REFRESH_DAILY
  WHERE usage_date >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY region_group, snowflake_region, fulfillment_group_name
),
l AS (
  SELECT d.region_group, d.snowflake_region, d.fulfillment_group_name,
         COUNT(DISTINCT TO_VARCHAR(f.value)) AS listings_count
  FROM SNOWFLAKE.DATA_SHARING_USAGE.LISTING_AUTO_FULFILLMENT_REFRESH_DAILY d,
       LATERAL FLATTEN(input => d.listings, outer => TRUE) f
  WHERE d.usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND d.usage_date < __AS_OF_DATE__
  GROUP BY d.region_group, d.snowflake_region, d.fulfillment_group_name
),
sd AS (
  SELECT region_group, snowflake_region, usage_date,
         SUM(COALESCE(average_database_bytes, 0) + COALESCE(average_failsafe_bytes, 0)) AS bytes
  FROM SNOWFLAKE.DATA_SHARING_USAGE.LISTING_AUTO_FULFILLMENT_DATABASE_STORAGE_DAILY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY region_group, snowflake_region, usage_date
),
st AS (
  SELECT region_group, snowflake_region, SUM(bytes) / :period_days AS avg_storage_bytes
  FROM sd
  GROUP BY region_group, snowflake_region
),
u AS (
  SELECT r.region_group, r.snowflake_region, r.fulfillment_group_name, COALESCE(l.listings_count, 0) AS listings_count,
         r.cur_credits, r.prev_credits, r.tb_transferred, r.active_days,
         100 * (r.cur_credits - r.prev_credits) / NULLIF(r.prev_credits, 0) AS change_pct,
         CAST(NULL AS DOUBLE) AS avg_storage_bytes
  FROM r LEFT JOIN l ON l.region_group = r.region_group AND l.snowflake_region = r.snowflake_region
                    AND l.fulfillment_group_name = r.fulfillment_group_name
  UNION ALL
  SELECT region_group, snowflake_region, '(storage)', CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
         CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), CAST(NULL AS DOUBLE), avg_storage_bytes
  FROM st
  WHERE avg_storage_bytes > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, region_group, snowflake_region,
       fulfillment_group_name, listings_count, cur_credits AS current_credits, prev_credits AS previous_credits,
       change_pct, 100 * active_days / :period_days AS active_days_pct, tb_transferred, avg_storage_bytes,
       cur_credits * __CREDIT_PRICE__ AS est_within_usd_list,
       prev_credits * __CREDIT_PRICE__ AS est_previous_usd_list,
       avg_storage_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS est_storage_usd_month,
       fulfillment_group_name = '(storage)' AS is_alt_basis,
       IFF(fulfillment_group_name = '(storage)', IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'unpriced', 'priced'),
           IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced')) AS price_basis,
       CASE WHEN fulfillment_group_name = '(storage)' AND __STORAGE_PRICE_TB_MONTH__ IS NULL THEN 'unpriced'
            WHEN fulfillment_group_name <> '(storage)' AND __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN fulfillment_group_name = '(storage)' THEN IFF(__STORAGE_PRICE_TB_MONTH__ IS NULL, 'NOT_ASSESSED', 'OK')
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_credits * __CREDIT_PRICE__ < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct OR listings_count = 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM u
ORDER BY current_credits DESC NULLS LAST, avg_storage_bytes DESC NULLS LAST
