-- query_id: sf_cost_marketplace_paid_listings
-- title: Paid Marketplace listing charges set against who reads the data
-- domain: cost   tier: standard
-- entity: paid listings = listing_global_name
-- windowed: yes
-- money: charge_amount
-- reads: SNOWFLAKE.DATA_SHARING_USAGE.MARKETPLACE_PAID_USAGE_DAILY, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise Edition for ACCESS_HISTORY (reads)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :crit_amount (default 1000) currency units: an unread listing charging this much or more reads CRITICAL
-- empty_if: no_activity, view_missing, ingestion_lag
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows (needs Enterprise Edition), so reads cannot be
--   judged; no_database: the listing row names no database, so reads cannot be matched
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Whether the view repeats a day's line across report dates is not
--   stated; the newest report date is kept per line.
-- read_this: one row = one paid listing in one currency. charge_amount is what the provider charged in the window
--   (fixed fees and usage charges, without tax, in the invoice currency, not discounted); fixed_amount is the
--   FIXED part. read_queries and readers count queries and users that read the listing's database. unread_amount
--   is the charge of a listing nobody read.
-- healthy: status = OK when someone reads the listing.
-- investigate_if: WARN when a listing that charged in the window was not read; CRITICAL when it charged
--   :crit_amount or more.
-- actions: 1) ask the data owner whether the listing is still needed (free); 2) cancel or downgrade the plan in
--   Snowsight under Data Products, Marketplace (spend); 3) drop the imported database once the subscription ends
--   (free)
-- next: sf_share_inbound_databases
-- caveats: Amounts are in the listing's currency and are never added across currencies. The view lags up to 48
--   hours. Reads through a Native App's own procedures are not attributed to its database. Consumers see only
--   their own account's charges.
WITH p AS (
  SELECT m.usage_date, m.listing_global_name, m.listing_display_name, m.provider_name, m.database_name,
         m.charge_type, m.currency, m.charge, m.units
  FROM (
    SELECT CAST(usage_date AS DATE) AS usage_date, listing_global_name, listing_display_name, provider_name,
           database_name, charge_type, unit_price, currency, charge, units,
           ROW_NUMBER() OVER (PARTITION BY CAST(usage_date AS DATE), listing_global_name, database_name, charge_type,
                                           unit_price, currency ORDER BY report_date DESC) AS rn
    FROM SNOWFLAKE.DATA_SHARING_USAGE.MARKETPLACE_PAID_USAGE_DAILY
    WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  ) m
  WHERE m.rn = 1
),
l AS (
  SELECT listing_global_name, MAX(listing_display_name) AS listing_display_name, MAX(provider_name) AS provider_name,
         MAX(database_name) AS database_name, currency,
         SUM(charge) AS charge_amount, SUM(IFF(UPPER(charge_type) = 'FIXED', charge, 0)) AS fixed_amount,
         SUM(TRY_TO_DOUBLE(TO_VARCHAR(units))) AS billed_units, COUNT(DISTINCT usage_date) AS charged_days
  FROM p
  GROUP BY listing_global_name, currency
),
ah AS (
  SELECT ah.query_id, ah.user_name, ah.query_start_time,
         UPPER(SPLIT_PART(f.value:objectName::STRING, '.', 1)) AS db_key
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT()))) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
reads AS (
  SELECT db_key, COUNT(DISTINCT query_id) AS read_queries, COUNT(DISTINCT user_name) AS readers,
         MAX(query_start_time) AS last_read_at
  FROM ah GROUP BY db_key
),
seen AS (
  SELECT COUNT(*) AS access_rows FROM ah
),
j AS (
  SELECT l.*, COALESCE(r.read_queries, 0) AS read_queries, COALESCE(r.readers, 0) AS readers, r.last_read_at,
         seen.access_rows
  FROM l
  LEFT JOIN reads r ON r.db_key = UPPER(l.database_name)
  CROSS JOIN seen
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, listing_global_name, listing_display_name,
       provider_name, database_name, currency, charge_amount, fixed_amount, billed_units, charged_days,
       read_queries, readers, last_read_at,
       IFF(access_rows > 0 AND database_name IS NOT NULL AND read_queries = 0 AND charge_amount > 0, charge_amount, NULL) AS unread_amount,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(access_rows > 0 AND database_name IS NOT NULL AND read_queries = 0 AND charge_amount > 0,
             'charged ' || ROUND(charge_amount, 2) || ' ' || COALESCE(currency, '') || ' and nobody read it', NULL)), '; ') AS reasons,
       CASE WHEN access_rows = 0 THEN 'no_access_history' WHEN database_name IS NULL THEN 'no_database' END AS not_assessed_reason,
       CASE
         WHEN access_rows = 0 OR database_name IS NULL THEN 'NOT_ASSESSED'
         WHEN read_queries = 0 AND charge_amount >= :crit_amount THEN 'CRITICAL'
         WHEN read_queries = 0 AND charge_amount > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END,
         charge_amount DESC, listing_global_name
