-- query_id: sf_use_streamlit_access
-- title: Who opened each Streamlit app, when and from where, and what the app ran as
-- domain: governance_access   tier: standard
-- entity: apps = app_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SESSIONS,
--   SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :lookback_days (default 90) days of QUERY_HISTORY it reads, counted back from the export date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Apps run with owner's rights, so the app's own queries
--   carry the owner; the open (the top-level ExecuteStreamlit query) is read as the viewer. Confirm on a
--   live account.
-- read_this: one row = one Streamlit app x kind x user x role x UTC day. kind open = the app starting or
--   rerunning for a viewer (the query Snowflake tags with the app name and no ChildQuery), with the
--   viewer's session client and sign-in IPs; kind app_query = queries the app ran itself ("ChildQuery":
--   "true"), with the user and role they ran as (the app owner under owner's rights). queries counts
--   statements, sessions distinct sessions; first_at and last_at are the first and last that day. Only the
--   app name is read from the tag; no query text.
-- healthy: status = OK on every row; this check is a log of app use, it does not judge.
-- investigate_if: n/a - inventory of app use
-- actions: 1) check that each viewer of an app that shows sensitive data is meant to see it; revoke the
--   role's USAGE on the app otherwise (free)
-- next: sf_acc_streamlit_shares
-- empty_if: role_cannot_see, no_activity
-- caveats: apps whose queries carry a custom QUERY_TAG are not seen. Sign-in IPs come from the session's
--   login; a session opened before the lookback reads none. Days are UTC.
WITH q AS (
  SELECT query_id, start_time, user_name, UPPER(role_name) AS role_name, session_id,
         UPPER(COALESCE(TRY_PARSE_JSON(query_tag):"StreamlitName"::STRING,
                        REGEXP_SUBSTR(query_tag, 'streamlitName: ?([^,]+)', 1, 1, 'e', 1))) AS app_name,
         COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(TRY_PARSE_JSON(query_tag):"ChildQuery")), FALSE) AS is_child
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_tag ILIKE '%streamlit%'
),
s AS (
  SELECT s.session_id, MAX(SPLIT_PART(s.client_application_id, ' ', 1)) AS client, MAX(l.client_ip) AS client_ip
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS s
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY l
    ON l.event_id = s.login_event_id AND l.event_timestamp >= DATEADD(day, -(:lookback_days + 7), __AS_OF_DATE__)
  WHERE s.created_on >= DATEADD(day, -(:lookback_days + 7), __AS_OF_DATE__)
    AND s.session_id IN (SELECT session_id FROM q)
  GROUP BY s.session_id
),
ut AS (
  SELECT name AS user_name, COALESCE(UPPER(type), 'NOT_SET') AS user_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, q.app_name, SPLIT_PART(q.app_name, '.', 1) AS database_name,
       SPLIT_PART(q.app_name, '.', 2) AS schema_name, IFF(q.is_child, 'app_query', 'open') AS kind,
       DATE(q.start_time) AS usage_date, q.user_name, MAX(COALESCE(u.user_type, 'UNKNOWN')) AS user_type, q.role_name,
       COUNT(*) AS queries, COUNT(DISTINCT q.session_id) AS sessions,
       LISTAGG(DISTINCT s.client, ', ') WITHIN GROUP (ORDER BY s.client) AS clients,
       ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT s.client_ip) WITHIN GROUP (ORDER BY s.client_ip), 0, 3), ', ') AS client_ips,
       MIN(q.start_time)::TIMESTAMP_NTZ AS first_at, MAX(q.start_time)::TIMESTAMP_NTZ AS last_at, 'OK' AS status
FROM q
LEFT JOIN s ON s.session_id = q.session_id
LEFT JOIN ut u ON u.user_name = q.user_name
WHERE q.app_name IS NOT NULL
GROUP BY q.app_name, q.is_child, DATE(q.start_time), q.user_name, q.role_name
ORDER BY usage_date DESC, app_name, kind, user_name
