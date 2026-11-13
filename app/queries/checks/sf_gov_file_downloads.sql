-- query_id: sf_gov_file_downloads
-- title: Files taken out: GET from stages and unloads, by user, stage and source table
-- domain: governance_access   tier: standard
-- entity: downloads = user_name, role_name, kind, stage_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SESSIONS, SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition for the stage and source tables
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one day x user x role x client x kind (GET = files downloaded from a stage,
--   UNLOAD = COPY INTO a stage or location) x stage. queries counts the statements, rows_unloaded and
--   outbound_gb come from QUERY_HISTORY. source_tables lists the tables an unload read (up to 10, with
--   source_table_count exact), sensitive_tables those of them with a sensitive-tagged column. stage_name is
--   the named or table stage, or '(user stage)'; the external URL is not kept. GB leaving the account and
--   its destinations are in sf_gov_data_egress, which also counts unloads: read GB there, not here.
-- healthy: status = OK for service users and for downloads with no sensitive source table.
-- investigate_if: WARN when a person unloaded a table with sensitive columns, or downloaded files with
--   GET from a stage that such an unload wrote to in the window.
-- actions: 1) ask the user why the data left and where it went (free); 2) attach a data movement policy
--   to the sensitive tables to alert on or block unloads and downloads (config)
-- next: sf_sec_data_movement_violations
-- empty_if: role_cannot_see, no_activity
-- caveats: Snowflake does not log result downloads from Snowsight or what a driver (ODBC, JDBC, Excel,
--   BI tools) fetches; the reads behind them are in sf_use_access_log by client. A GET that succeeds means
--   Snowflake allowed the transfer, not that the file arrived. Stage and source tables need ACCESS_HISTORY
--   (Enterprise); without it they are NULL.
WITH __INCLUDE_sf_gov_sensitive_columns__,
__INCLUDE_sf_sec_users__,
q AS (
  SELECT query_id, start_time, user_name, UPPER(role_name) AS role_name, session_id,
         IFF(query_type = 'GET_FILES', 'GET', 'UNLOAD') AS kind, COALESCE(rows_unloaded, 0) AS rows_unloaded,
         COALESCE(outbound_data_transfer_bytes, 0) AS outbound_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type IN ('GET_FILES', 'UNLOAD') AND execution_status = 'SUCCESS'
),
ah AS (
  SELECT query_id, base_objects_accessed, direct_objects_accessed, objects_modified
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
    AND query_id IN (SELECT query_id FROM q)
),
stages AS (
  -- a user stage is named after its user: keep the user in user_name (masked as a user), not here
  SELECT a.query_id, MAX(IFF(f.value:"stageKind"::STRING ILIKE 'user%', '(user stage)',
                             UPPER(f.value:"objectName"::STRING))) AS stage_name
  FROM ah a, LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(a.objects_modified, ARRAY_CONSTRUCT()),
                                                 COALESCE(a.direct_objects_accessed, ARRAY_CONSTRUCT()))) f
  WHERE f.value:"stageKind" IS NOT NULL OR UPPER(f.value:"objectDomain"::STRING) = 'STAGE'
  GROUP BY a.query_id
),
src AS (
  SELECT DISTINCT a.query_id, UPPER(f.value:"objectName"::STRING) AS table_fqn
  FROM ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  WHERE UPPER(f.value:"objectDomain"::STRING) IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'EXTERNAL TABLE',
                                                  'MATERIALIZED VIEW')
),
sens AS (
  SELECT DISTINCT database_name || '.' || schema_name || '.' || table_name AS table_fqn FROM sf_gov_sensitive_columns
),
src_s AS (
  SELECT s.query_id, s.table_fqn, x.table_fqn IS NOT NULL AS is_sensitive
  FROM src s LEFT JOIN sens x ON x.table_fqn = s.table_fqn
),
ss AS (
  SELECT session_id, MAX(SPLIT_PART(client_application_id, ' ', 1)) AS client
  FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
  WHERE created_on >= DATEADD(day, -(:period_days + 7), __AS_OF_DATE__)
    AND session_id IN (SELECT session_id FROM q)
  GROUP BY session_id
),
rows_q AS (
  SELECT q.*, DATE(q.start_time) AS usage_date, COALESCE(NULLIF(ss.client, ''), 'unknown') AS client,
         COALESCE(st.stage_name, '(not in ACCESS_HISTORY)') AS stage_name
  FROM q
  LEFT JOIN ss ON ss.session_id = q.session_id
  LEFT JOIN stages st ON st.query_id = q.query_id
),
-- stages that an unload of a sensitive table wrote to: a later GET from them takes that data out
sens_stages AS (
  SELECT DISTINCT r.stage_name
  FROM rows_q r JOIN src_s s ON s.query_id = r.query_id AND s.is_sensitive
  WHERE r.kind = 'UNLOAD'
),
g AS (
  SELECT r.usage_date, r.user_name, r.role_name, r.client, r.kind, r.stage_name,
         COUNT(DISTINCT r.query_id) AS queries, SUM(r.rows_unloaded) AS rows_unloaded,
         SUM(r.outbound_bytes) / POWER(1024, 3) AS outbound_gb,
         MIN(r.start_time) AS first_at, MAX(r.start_time) AS last_at
  FROM rows_q r
  GROUP BY 1, 2, 3, 4, 5, 6
),
t AS (
  SELECT r.usage_date, r.user_name, r.role_name, r.client, r.kind, r.stage_name,
         COUNT(DISTINCT s.table_fqn) AS source_table_count,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT s.table_fqn) WITHIN GROUP (ORDER BY s.table_fqn), 0, 10), ', ') AS source_tables,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT IFF(s.is_sensitive, s.table_fqn, NULL))
                         WITHIN GROUP (ORDER BY IFF(s.is_sensitive, s.table_fqn, NULL)), 0, 10), ', ') AS sensitive_tables,
         COUNT(DISTINCT IFF(s.is_sensitive, s.table_fqn, NULL)) AS sensitive_table_count
  FROM rows_q r JOIN src_s s ON s.query_id = r.query_id
  GROUP BY 1, 2, 3, 4, 5, 6
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, g.usage_date, g.user_name,
       COALESCE(u.user_type, 'UNKNOWN') AS user_type, g.role_name, g.client, g.kind, g.stage_name,
       g.queries, g.rows_unloaded, g.outbound_gb, COALESCE(t.source_table_count, 0) AS source_table_count,
       NULLIF(t.source_tables, '') AS source_tables, NULLIF(t.sensitive_tables, '') AS sensitive_tables,
       COALESCE(t.sensitive_table_count, 0) AS sensitive_table_count,
       ss2.stage_name IS NOT NULL AS stage_had_sensitive_unload, g.first_at, g.last_at,
       CASE WHEN COALESCE(u.user_type, 'UNKNOWN') IN ('SERVICE', 'LEGACY_SERVICE') THEN 'OK'
            WHEN COALESCE(t.sensitive_table_count, 0) > 0 THEN 'WARN'
            WHEN g.kind = 'GET' AND ss2.stage_name IS NOT NULL THEN 'WARN'
            ELSE 'OK' END AS status
FROM g
LEFT JOIN t ON t.usage_date = g.usage_date AND t.user_name IS NOT DISTINCT FROM g.user_name
 AND t.role_name IS NOT DISTINCT FROM g.role_name AND t.client = g.client AND t.kind = g.kind
 AND t.stage_name = g.stage_name
LEFT JOIN sf_sec_users u ON u.user_name = g.user_name
LEFT JOIN sens_stages ss2 ON ss2.stage_name = g.stage_name AND ss2.stage_name <> '(not in ACCESS_HISTORY)'
ORDER BY g.usage_date DESC, g.user_name, g.kind
