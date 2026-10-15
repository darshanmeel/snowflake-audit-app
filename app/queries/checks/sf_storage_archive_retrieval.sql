-- query_id: sf_storage_archive_retrieval
-- title: Archive tiers: data pulled back from COOL/COLD and what archiving costs
-- domain: storage   tier: standard
-- entity: archived objects = database_name, schema_name, object_name
-- windowed: yes
-- money: est_current_usd_list
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ARCHIVE_STORAGE_DATA_RETRIEVAL_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_retrieval_days (default 3) days: an object retrieved on this many days or more flags;
--   :warn_gb (default 100) gb: a retrieval above this on either tier flags
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Lifecycle policy failures are not read: their columns
--   are not confirmed and the view carries the policy text.
-- read_this: one row = one object with data retrieved from an archive tier plus one archive
--   services row (not counted as an object). The object rows show GB retrieved and on how many days. The services row shows
--   the credits of writing to the archive, processing retrieved files and running lifecycle policies,
--   priced at the credit price, with the archive size now in GB and the standard-tier space COLD retrievals
--   hold temporarily (retrieval_temp_gb_now). Per-GB retrieval fees and archive storage
--   rates are in no view, so those are GB only, never $0.
-- healthy: status = OK when archived data is rarely pulled back and no retrieval is large.
-- investigate_if: WARN when an object is retrieved on :warn_retrieval_days days or more (the lifecycle
--   policy archives data that is still in use) or a retrieval on either tier is over :warn_gb GB. COLD retrieval costs less per GB than COOL, but holds
--   temporary standard storage until the data is used.
-- actions: 1) lengthen the lifecycle policy age on tables that are read again (config); 2) stop archiving
--   tables that are queried weekly (config); 3) restore data once instead of reading it archived (free)
-- next: sf_storage_retention_policy
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the archive services
--   credits cannot be priced
-- caveats: Archive storage itself is billed at the archive rate on the storage pages, not here. The services
--   credits are METERING_HISTORY credits with no cloud-services adjustment (none applies to these types).
--   Latest-day STORAGE_USAGE values are used for sizes. Retrieval lags up to 1 hour, the other views up to 3 hours.
WITH r AS (
  SELECT database_id, schema_id, object_id, MAX(object_type) AS object_type,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(object_name) AS object_name,
         archive_storage_tier,
         SUM(bytes) / POWER(1024, 3) AS gb_retrieved,
         COUNT(DISTINCT CAST(start_time AS DATE)) AS retrieval_days
  FROM SNOWFLAKE.ACCOUNT_USAGE.ARCHIVE_STORAGE_DATA_RETRIEVAL_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY database_id, schema_id, object_id, archive_storage_tier
),
sv AS (
  SELECT SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
  WHERE service_type IN ('ARCHIVE_STORAGE_WRITE', 'ARCHIVE_STORAGE_RETRIEVAL_FILE_PROCESSING',
                         'STORAGE_LIFECYCLE_POLICY_EXECUTION')
    AND start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
st AS (
  SELECT archive_storage_cool_bytes AS cool_bytes, archive_storage_cold_bytes AS cold_bytes,
         archive_storage_retrieval_temp_bytes AS temp_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
  WHERE usage_date < __AS_OF_DATE__
  ORDER BY usage_date DESC
  LIMIT 1
),
u AS (
  SELECT 'object' AS row_kind, database_name, database_id, schema_name, schema_id, object_name, object_id, object_type,
         archive_storage_tier, gb_retrieved, retrieval_days, CAST(NULL AS DOUBLE) AS credits,
         CAST(NULL AS DOUBLE) AS cool_gb, CAST(NULL AS DOUBLE) AS cold_gb, CAST(NULL AS DOUBLE) AS temp_gb
  FROM r
  UNION ALL
  SELECT 'services', CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER),
         CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
         CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), COALESCE(sv.credits, 0),
         COALESCE(st.cool_bytes, 0) / POWER(1024, 3), COALESCE(st.cold_bytes, 0) / POWER(1024, 3),
         COALESCE(st.temp_bytes, 0) / POWER(1024, 3)
  FROM sv LEFT JOIN st ON TRUE
  WHERE COALESCE(sv.credits, 0) > 0 OR COALESCE(st.cool_bytes, 0) + COALESCE(st.cold_bytes, 0) > 0
),
f AS (
  SELECT u.*, row_kind = 'object' AND retrieval_days >= :warn_retrieval_days AS often,
         row_kind = 'object' AND gb_retrieved > :warn_gb AS big_retrieval
  FROM u
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind, database_name, database_id, schema_name,
       schema_id, object_name, object_id, object_type, archive_storage_tier, gb_retrieved, retrieval_days,
       credits AS archive_services_credits, cool_gb AS archive_cool_gb_now, cold_gb AS archive_cold_gb_now, temp_gb AS retrieval_temp_gb_now,
       IFF(row_kind = 'services', '(archive services)', NULL) AS row_label,
       IFF(row_kind = 'services', credits * __CREDIT_PRICE__, NULL) AS est_current_usd_list,
       IFF(row_kind = 'services', IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced'), NULL) AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(often, 'retrieved on ' || retrieval_days || ' days', NULL),
         IFF(big_retrieval, ROUND(gb_retrieved, 0) || ' GB pulled back from ' || archive_storage_tier, NULL)), '; ') AS reasons,
       CASE WHEN row_kind = 'services' AND credits > 0 AND __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN row_kind = 'services' AND credits > 0 AND __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN often OR big_retrieval THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY IFF(often OR big_retrieval, 0, 1), gb_retrieved DESC NULLS LAST, object_name
