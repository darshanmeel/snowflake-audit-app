-- query_id: sf_use_access_hours
-- title: When people use each table, view and stage, hour by hour, and what falls outside business hours
-- domain: governance_access   tier: standard
-- entity: people = user_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition
-- params: :lookback_days (default 90) days of ACCESS_HISTORY it reads, counted back from the export date;
--   :business_utc_offset (default 0) hours business time is ahead of UTC (e.g. 1 for Zurich in winter, -5
--   for New York); :business_start_hour (default 7) local hour business hours start; :business_end_hour
--   (default 19) local hour they end (Saturday and Sunday are off hours all day); :row_cap (default
--   1000000) rows: the export keeps at most this many, newest hours first
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one person x object x role x client x statement type x UTC hour (usage_date and
--   hour_utc). People are users whose TYPE is PERSON; service users, SYSTEM (tasks), users with no TYPE and
--   dropped users are left out. queries, read_queries, write_queries and ddl_queries count distinct queries.
--   is_off_hours is judged at :business_utc_offset; the page can shift the offset and recount without a
--   new export, because every row keeps its UTC hour.
-- healthy: status = OK when people use objects in business hours.
-- investigate_if: WARN when a person ran queries on an object outside business hours at the configured
--   offset; NOT_ASSESSED when ACCESS_HISTORY has no rows in the lookback.
-- actions: 1) ask the person why they used the data off hours, starting with sensitive objects and changes
--   (free); 2) set business_utc_offset and the business hours for the account in config/thresholds.yml (config)
-- next: sf_use_access_log
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the lookback (Standard edition, or
--   the role cannot see it), so off-hours use cannot be told from none
-- caveats: one offset for the whole account: daylight saving and people in other time zones read as off
--   hours by an hour or more. ACCESS_HISTORY lags up to 3 hours.
WITH __INCLUDE_sf_use_access_rows__,
p AS (
  SELECT e.*, DATEADD(hour, :business_utc_offset, e.query_start_time) AS local_at
  FROM sf_acc_rows e
  WHERE e.user_type = 'PERSON' AND e.user_name <> 'SYSTEM'
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, DATE(p.query_start_time) AS usage_date,
       HOUR(p.query_start_time) AS hour_utc, p.user_name, p.object_domain,
       MAX(p.object_name) AS object_fqn, p.role_name, p.client, p.statement_type,
       COUNT(DISTINCT p.query_id) AS queries,
       COUNT(DISTINCT IFF(p.kind = 'read', p.query_id, NULL)) AS read_queries,
       COUNT(DISTINCT IFF(p.kind = 'write', p.query_id, NULL)) AS write_queries,
       COUNT(DISTINCT IFF(p.kind = 'ddl', p.query_id, NULL)) AS ddl_queries,
       BOOLOR_AGG(DAYOFWEEKISO(p.local_at) >= 6 OR HOUR(p.local_at) < :business_start_hour
                  OR HOUR(p.local_at) >= :business_end_hour) AS is_off_hours,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       IFF(BOOLOR_AGG(DAYOFWEEKISO(p.local_at) >= 6 OR HOUR(p.local_at) < :business_start_hour
                      OR HOUR(p.local_at) >= :business_end_hour), 'WARN', 'OK') AS status
FROM p
GROUP BY DATE(p.query_start_time), HOUR(p.query_start_time), p.user_name, p.object_domain, p.object_id,
         IFF(p.object_id IS NULL, p.object_name, NULL), p.role_name, p.client, p.statement_type
UNION ALL
SELECT 0, __ACCOUNT_ID__, CAST(NULL AS DATE), CAST(NULL AS INTEGER), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS INTEGER), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER),
       CAST(NULL AS BOOLEAN), 'no_access_history', 'NOT_ASSESSED'
FROM sf_acc_seen WHERE access_rows = 0
ORDER BY usage_date DESC NULLS FIRST, hour_utc DESC, user_name
