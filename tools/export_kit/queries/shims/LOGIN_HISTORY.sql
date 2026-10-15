-- shim: LOGIN_HISTORY
-- reads: INFORMATION_SCHEMA.LOGIN_HISTORY (table function)
-- note: sign-ins for the last 7 days at most, only the users this role can monitor, up to 10,000 a day
-- Seven one-day calls of up to 10,000 events each, the oldest starting 5 minutes inside the 7-day limit.
SELECT event_id, event_timestamp, event_type, user_name, client_ip, reported_client_type, reported_client_version,
       first_authentication_factor, second_authentication_factor, is_success, error_code, error_message,
       related_event_id, connection, client_private_link_id, first_authentication_factor_id,
       second_authentication_factor_id, login_details, CAST(NULL AS VARCHAR) AS authorizing_integration_name
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
