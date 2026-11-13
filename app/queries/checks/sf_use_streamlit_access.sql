-- query_id: sf_use_streamlit_access
-- title: Who opened each Streamlit app, and when
-- domain: governance_access   tier: standard
-- entity: apps = app_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :lookback_days (default 90) days of QUERY_HISTORY it reads, counted back from the export date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Snowflake's docs do not say whether user_name on a Streamlit
--   query is the viewer or the app owner; confirm on a live account before reading it as the viewer.
-- read_this: one row = one Streamlit app x user x role x UTC day. Streamlit in Snowflake tags its queries
--   with the app's name ({"StreamlitEngine": "ExecuteStreamlit", "StreamlitName": "DB.SCHEMA.APP"}, or the
--   older text form); runs counts the app's own queries (the app starting or rerunning for that user),
--   child_queries the queries the app ran for them ("ChildQuery": "true"). first_at and last_at are the first
--   and last of them that day. Only the app name is read from the tag; no query text.
-- healthy: status = OK on every row; this check is a log of app use, it does not judge.
-- investigate_if: n/a - inventory of app use
-- actions: 1) check that each user of an app that shows sensitive data is meant to see it; revoke USAGE on
--   the app otherwise (free)
-- next: sf_use_access_log
-- empty_if: role_cannot_see, no_activity
-- caveats: apps whose queries carry no Streamlit tag (a custom QUERY_TAG set in the app) are not seen. A
--   viewer who opens an app and runs nothing may leave only the app's own query. Days are UTC.
WITH q AS (
  SELECT query_id, start_time, user_name, UPPER(role_name) AS role_name,
         UPPER(COALESCE(TRY_PARSE_JSON(query_tag):"StreamlitName"::STRING,
                        REGEXP_SUBSTR(query_tag, 'streamlitName: ?([^,]+)', 1, 1, 'e', 1))) AS app_name,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(TRY_PARSE_JSON(query_tag):"ChildQuery")), FALSE) AS is_child
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_tag ILIKE '%streamlit%'
),
ut AS (
  SELECT name AS user_name, COALESCE(UPPER(type), 'NOT_SET') AS user_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, q.app_name, SPLIT_PART(q.app_name, '.', 1) AS database_name,
       SPLIT_PART(q.app_name, '.', 2) AS schema_name, DATE(q.start_time) AS usage_date, q.user_name,
       MAX(COALESCE(u.user_type, 'UNKNOWN')) AS user_type, q.role_name,
       COUNT_IF(NOT q.is_child) AS runs, COUNT_IF(q.is_child) AS child_queries,
       MIN(q.start_time)::TIMESTAMP_NTZ AS first_at, MAX(q.start_time)::TIMESTAMP_NTZ AS last_at, 'OK' AS status
FROM q
LEFT JOIN ut u ON u.user_name = q.user_name
WHERE q.app_name IS NOT NULL
GROUP BY q.app_name, DATE(q.start_time), q.user_name, q.role_name
ORDER BY usage_date DESC, app_name, user_name
