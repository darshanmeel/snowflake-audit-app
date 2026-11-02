-- One role per query in the window: MAX(role_name) from QUERY_HISTORY, limited to the queries in ACCESS_HISTORY.
sf_use_query_roles AS (
  SELECT q.query_id, MAX(UPPER(q.role_name)) AS role_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  WHERE q.start_time >= DATEADD(day, -(:period_days + 1), __AS_OF_DATE__)
    AND q.query_id IN (SELECT query_id FROM sf_use_ah)
  GROUP BY q.query_id
)
