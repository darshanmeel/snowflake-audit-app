-- ACCESS_HISTORY over :lookback_days flattened to one event per query x object x kind (read, write, ddl),
-- with the query's role and statement type, its session's client and the user's TYPE today. Columns of
-- sf_acc_rows: query_id, query_start_time (UTC), user_name, kind, object_domain, object_id, object_name,
-- ddl_operation, statement_type, role_name, client, user_type, via. via is 'procedure DB.S.P' when the query ran
-- inside a CALL (ACCESS_HISTORY.root_query_id) and 'streamlit DB.S.APP' when its QUERY_TAG names a Streamlit app
-- (only the app name is read from the tag). sf_acc_seen holds access_rows.
-- Only ids, names and types, never query text.
sf_acc_ah AS (
  SELECT query_id, query_start_time, user_name, base_objects_accessed, direct_objects_accessed,
         objects_modified, object_modified_by_ddl, root_query_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__)
    AND query_start_time < __AS_OF_DATE__
),
sf_acc_raw AS (
  SELECT a.query_id, a.query_start_time, a.user_name, 'read' AS kind,
         UPPER(f.value:"objectDomain"::STRING) AS object_domain, f.value:"objectId"::NUMBER AS object_id,
         UPPER(f.value:"objectName"::STRING) AS object_name, CAST(NULL AS VARCHAR) AS ddl_operation
  FROM sf_acc_ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  -- views, stages and functions read directly; base tables are already above
  SELECT a.query_id, a.query_start_time, a.user_name, 'read',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER, UPPER(f.value:"objectName"::STRING),
         CAST(NULL AS VARCHAR)
  FROM sf_acc_ah a, LATERAL FLATTEN(input => a.direct_objects_accessed) f
  WHERE UPPER(f.value:"objectDomain"::STRING) NOT IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE',
                                                       'EXTERNAL TABLE', 'MATERIALIZED VIEW')
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'write',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER, UPPER(f.value:"objectName"::STRING),
         CAST(NULL AS VARCHAR)
  FROM sf_acc_ah a, LATERAL FLATTEN(input => a.objects_modified) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'ddl',
         UPPER(COALESCE(a.object_modified_by_ddl:"objectDomain"::STRING, 'UNKNOWN')),
         a.object_modified_by_ddl:"objectId"::NUMBER, UPPER(a.object_modified_by_ddl:"objectName"::STRING),
         UPPER(a.object_modified_by_ddl:"operationType"::STRING)
  FROM sf_acc_ah a
  WHERE a.object_modified_by_ddl IS NOT NULL
),
-- the procedure a CALL ran: its queries carry the CALL as root_query_id
sf_acc_proc AS (
  SELECT a.query_id, MAX(UPPER(f.value:"objectName"::STRING)) AS proc
  FROM sf_acc_ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  WHERE UPPER(f.value:"objectDomain"::STRING) = 'PROCEDURE'
  GROUP BY a.query_id
),
sf_acc_qh AS (
  SELECT query_id, MAX(UPPER(role_name)) AS role_name, MAX(session_id) AS session_id, MAX(query_type) AS query_type,
         -- Streamlit tags are JSON ({"StreamlitName": "DB.S.APP"}), or the older text form (streamlitName: DB.S.APP)
         MAX(UPPER(COALESCE(TRY_PARSE_JSON(query_tag):"StreamlitName"::STRING,
                            REGEXP_SUBSTR(query_tag, 'streamlitName: ?([^,]+)', 1, 1, 'e', 1)))) AS app
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -(:lookback_days + 1), __AS_OF_DATE__)
    AND query_id IN (SELECT query_id FROM sf_acc_ah)
  GROUP BY query_id
),
sf_acc_ss AS (
  SELECT session_id, MAX(SPLIT_PART(client_application_id, ' ', 1)) AS client
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  -- a margin for sessions opened before the lookback; without a bound Snowflake scans a year of sessions
  WHERE created_on >= DATEADD(day, -(:lookback_days + 7), __AS_OF_DATE__)
    AND session_id IN (SELECT session_id FROM sf_acc_qh)
  GROUP BY session_id
),
sf_acc_ut AS (
  -- the raw TYPE: older service users often have none, and must not read as people
  SELECT name AS user_name, COALESCE(UPPER(type), 'NOT_SET') AS user_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE deleted_on IS NULL
),
sf_acc_rows AS (
  SELECT DISTINCT r.query_id, r.query_start_time, r.user_name, r.kind, r.object_domain, r.object_id, r.object_name,
         r.ddl_operation, COALESCE(q.query_type, 'UNKNOWN') AS statement_type,
         COALESCE(q.role_name, '(unknown role)') AS role_name,
         -- tasks run as SYSTEM with no session; other queries without one are said so, not "unknown"
         COALESCE(NULLIF(s.client, ''), IFF(r.user_name = 'SYSTEM', 'task', 'no session')) AS client,
         COALESCE(u.user_type, 'UNKNOWN') AS user_type,
         COALESCE('procedure ' || p.proc, 'streamlit ' || q.app) AS via
  FROM sf_acc_raw r
  -- a MERGE or INSERT ... SELECT from itself is a write, not a read of its target
  LEFT JOIN sf_acc_raw w ON r.kind = 'read' AND w.kind = 'write' AND w.query_id = r.query_id AND w.object_id = r.object_id
  LEFT JOIN sf_acc_qh q ON q.query_id = r.query_id
  LEFT JOIN sf_acc_ss s ON s.session_id = q.session_id
  LEFT JOIN sf_acc_ut u ON u.user_name = r.user_name
  LEFT JOIN sf_acc_ah ra ON ra.query_id = r.query_id AND ra.root_query_id <> r.query_id
  LEFT JOIN sf_acc_proc p ON p.query_id = ra.root_query_id
  WHERE r.object_name IS NOT NULL AND w.query_id IS NULL
),
sf_acc_seen AS (
  SELECT COUNT(*) AS access_rows FROM sf_acc_ah
)
