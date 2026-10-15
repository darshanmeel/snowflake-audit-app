-- query_id: access_login_concentration
-- reads: INFORMATION_SCHEMA.LOGIN_HISTORY (table function)
-- fallback_note: last 7 days at most, only the users this role can monitor, up to 10,000 sign-ins a day
-- Same columns as checks/access_login_concentration.sql. Seven one-day calls of up to 10,000 events
-- each, the oldest starting 5 minutes inside the 7-day limit, one row per event id.
WITH raw AS (
  SELECT event_id, user_name, client_ip, reported_client_type, first_authentication_factor, is_success, event_timestamp
  FROM (
    SELECT * FROM TABLE(__INFO_SCHEMA__.LOGIN_HISTORY(TIME_RANGE_START => DATEADD(day, -1, CURRENT_TIMESTAMP()),
      TIME_RANGE_END => CURRENT_TIMESTAMP(), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT * FROM TABLE(__INFO_SCHEMA__.LOGIN_HISTORY(TIME_RANGE_START => DATEADD(day, -2, CURRENT_TIMESTAMP()),
      TIME_RANGE_END => DATEADD(day, -1, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT * FROM TABLE(__INFO_SCHEMA__.LOGIN_HISTORY(TIME_RANGE_START => DATEADD(day, -3, CURRENT_TIMESTAMP()),
      TIME_RANGE_END => DATEADD(day, -2, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT * FROM TABLE(__INFO_SCHEMA__.LOGIN_HISTORY(TIME_RANGE_START => DATEADD(day, -4, CURRENT_TIMESTAMP()),
      TIME_RANGE_END => DATEADD(day, -3, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT * FROM TABLE(__INFO_SCHEMA__.LOGIN_HISTORY(TIME_RANGE_START => DATEADD(day, -5, CURRENT_TIMESTAMP()),
      TIME_RANGE_END => DATEADD(day, -4, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT * FROM TABLE(__INFO_SCHEMA__.LOGIN_HISTORY(TIME_RANGE_START => DATEADD(day, -6, CURRENT_TIMESTAMP()),
      TIME_RANGE_END => DATEADD(day, -5, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
    UNION ALL
    SELECT * FROM TABLE(__INFO_SCHEMA__.LOGIN_HISTORY(TIME_RANGE_START => DATEADD(minute, -10075, CURRENT_TIMESTAMP()),
      TIME_RANGE_END => DATEADD(day, -6, CURRENT_TIMESTAMP()), RESULT_LIMIT => 10000))
  )
  QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_timestamp) = 1
),
base AS (
  SELECT user_name, client_ip, reported_client_type, first_authentication_factor, is_success, event_timestamp
  FROM raw
  WHERE event_timestamp >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND event_timestamp < __AS_OF_DATE__
),
principal_ips AS (
  SELECT user_name, COUNT(DISTINCT client_ip) AS distinct_source_ips
  FROM base
  GROUP BY user_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, COALESCE(b.user_name, '(no user name)') AS principal,
       b.client_ip AS source_ip_address, b.reported_client_type AS service_name,
       b.first_authentication_factor AS action_name,
       COUNT(*) AS event_count,
       COUNT_IF(b.is_success = 'YES') AS success_count,
       COUNT_IF(b.is_success IS DISTINCT FROM 'YES') AS non_success_count,
       MAX(p.distinct_source_ips) AS distinct_source_ips,
       MIN(b.event_timestamp) AS first_event_time, MAX(b.event_timestamp) AS last_event_time,
       CASE
         WHEN COUNT_IF(b.is_success IS DISTINCT FROM 'YES') >= :crit_failed_logins THEN 'CRITICAL'
         WHEN COUNT_IF(b.is_success IS DISTINCT FROM 'YES') >= :warn_failed_logins THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM base b
LEFT JOIN principal_ips p ON p.user_name IS NOT DISTINCT FROM b.user_name
GROUP BY b.user_name, b.client_ip, b.reported_client_type, b.first_authentication_factor
ORDER BY non_success_count DESC
