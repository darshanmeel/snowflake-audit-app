-- query_id: sf_gov_shares_and_listings
-- shims: SHARES
-- reads: INFORMATION_SCHEMA table functions SHOW SHARES
-- fallback_note: live outbound shares only
-- pre: SHOW SHARES
WITH s AS (
  SELECT sh."created_on" AS created_on, UPPER(sh."kind") AS share_kind, sh."name" AS share_name,
         sh."database_name" AS database_name, sh."to" AS consumer_accounts, sh."owner" AS owner_role,
         sh."owner_account" AS owner_account, sh."comment" AS share_comment,
         NULLIF(sh."listing_global_name", '') AS listing_global_name
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) sh
),
-- SHOW SHARES has no secure-objects flag; the SHARES view (outbound shares, lags ~2 h) does.
sec AS (
  SELECT UPPER(name) AS share_key,
         BOOLAND_AGG(IFF(LOWER(TO_VARCHAR(secure_objects_only)) IN ('true', 'yes'), TRUE,
                         IFF(LOWER(TO_VARCHAR(secure_objects_only)) IN ('false', 'no'), FALSE, NULL))) AS secure_objects_only
  FROM __SHIM_SHARES__
  WHERE deleted_on IS NULL
  GROUP BY 1
),
lah AS (
  SELECT UPPER(o:SHARE_NAME::VARCHAR) AS share_name,
         COUNT(*) AS listing_access_rows,
         SUM(COALESCE(TRY_TO_NUMBER(TO_VARCHAR(o:QUERY_COUNT)), 1)) AS listing_queries,
         COUNT(DISTINCT COALESCE(o:CONSUMER_ACCOUNT_NAME::VARCHAR, o:CONSUMER_ACCOUNT_LOCATOR::VARCHAR)) AS listing_consumer_accounts,
         MAX(TRY_TO_DATE(TO_VARCHAR(o:QUERY_DATE))) AS last_listing_access
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o FROM SNOWFLAKE.DATA_SHARING_USAGE.LISTING_ACCESS_HISTORY)
  WHERE TRY_TO_DATE(TO_VARCHAR(o:QUERY_DATE)) >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND TRY_TO_DATE(TO_VARCHAR(o:QUERY_DATE)) < __AS_OF_DATE__
  GROUP BY 1
),
j AS (
  SELECT s.*,
         IFF(NULLIF(TRIM(s.consumer_accounts), '') IS NULL, 0,
             ARRAY_SIZE(SPLIT(s.consumer_accounts, ','))) AS consumer_count,
         sec.secure_objects_only,
         l.listing_queries, l.listing_consumer_accounts, l.last_listing_access
  FROM s
  LEFT JOIN sec ON sec.share_key = UPPER(SPLIT_PART(s.share_name, '.', -1))
  LEFT JOIN lah l ON l.share_name = UPPER(SPLIT_PART(s.share_name, '.', -1))
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, share_kind, share_name, database_name,
       owner_role, owner_account, consumer_count, consumer_accounts, listing_global_name, secure_objects_only,
       COALESCE(listing_queries, 0) AS listing_queries, COALESCE(listing_consumer_accounts, 0) AS listing_consumer_accounts,
       last_listing_access, created_on, share_comment,
       IFF(share_kind = 'OUTBOUND', ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         consumer_count || ' consumer accounts',
         IFF(consumer_count = 0 AND listing_global_name IS NULL, 'no consumers', NULL),
         IFF(consumer_count >= :warn_consumers, 'widely shared', NULL),
         IFF(secure_objects_only = FALSE, 'non-secure objects allowed', NULL),
         IFF(listing_global_name IS NOT NULL, 'listing ' || listing_global_name, NULL)), '; '), 'inbound share') AS reasons,
       IFF(share_kind = 'OUTBOUND' AND secure_objects_only IS NULL, 'no_share_record', NULL) AS not_assessed_reason,
       CASE
         WHEN share_kind <> 'OUTBOUND' THEN 'OK'
         WHEN secure_objects_only IS NULL THEN 'NOT_ASSESSED'
         WHEN secure_objects_only = FALSE
              AND (consumer_count >= :warn_consumers
                   OR (listing_global_name IS NOT NULL AND COALESCE(listing_consumer_accounts, 0) > 0)) THEN 'CRITICAL'
         WHEN (consumer_count = 0 AND listing_global_name IS NULL) OR consumer_count >= :warn_consumers
              OR secure_objects_only = FALSE THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, share_kind DESC, share_name
