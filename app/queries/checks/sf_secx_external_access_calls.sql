-- query_id: sf_secx_external_access_calls
-- title: Code calling out of Snowflake: hosts, denied calls and bytes sent, by user and role
-- domain: governance_access   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.EXTERNAL_ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_sent_mb (default 100) MB: sent at or above this the row reads WARN; :crit_sent_mb
--   (default 10000) MB: sent at or above this the row reads CRITICAL; :crit_denied (default 20) calls:
--   denied calls at or above this read CRITICAL
-- empty_if: view_missing, no_activity, ingestion_lag
-- not_assessed_reasons: query_not_in_history: the calls' queries are gone from QUERY_HISTORY, so their time and caller are unknown
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user x role x host list of calls to outside hosts, plus context rows for billed
--   transfer and unmatched queries. row_kind UNKNOWN_TIME = calls whose query is no longer in
--   QUERY_HISTORY. row_kind TIE_OUT = EXTERNAL_ACCESS bytes billed as transfer in DATA_TRANSFER_HISTORY
--   for the window, shown next to the sent bytes it should roughly match.
-- healthy: status = OK for calls that are allowed and small.
-- investigate_if: WARN when calls were denied or sent bytes reach :warn_sent_mb MB; CRITICAL at
--   :crit_denied or more denied calls or :crit_sent_mb MB sent. UNKNOWN_TIME rows read NOT_ASSESSED.
-- actions: 1) confirm each host with the code owner and remove rules for hosts nobody knows (free); 2)
--   list exact hosts in the network rules an external access integration uses (config); 3) revoke USAGE
--   on integrations from roles that do not need them (config)
-- next: sf_secx_network_rule_exposure
-- caveats: the view has no time or user, so both come from QUERY_HISTORY. Grain is one row per query
--   and IP, so a query with several IPs appears under each host list; totals across rows can count a
--   call twice. Covers UDF and procedure egress only. Lags up to 3 hours. Transfer bytes in
--   DATA_TRANSFER_HISTORY are only what crosses regions, so they are lower than bytes sent.
WITH __INCLUDE_sf_sec_users__,
-- One row per query and IP: the source can repeat rows, and bytes must count once.
eah AS (
  SELECT query_id, ip, hostnames, status,
         TRY_TO_NUMBER(TO_VARCHAR(sent_bytes)) AS sent_bytes,
         TRY_TO_NUMBER(TO_VARCHAR(received_bytes)) AS received_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.EXTERNAL_ACCESS_HISTORY
  QUALIFY ROW_NUMBER() OVER (PARTITION BY query_id, ip ORDER BY status) = 1
),
qh AS (
  SELECT query_id, user_name, role_name, start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE query_id IN (SELECT query_id FROM eah)
),
j AS (
  SELECT e.query_id, e.hostnames, e.status, e.sent_bytes, e.received_bytes,
         q.user_name, q.role_name, q.start_time,
         q.query_id IS NOT NULL AS time_known
  FROM eah e
  LEFT JOIN qh q ON q.query_id = e.query_id
  WHERE q.query_id IS NULL
     OR (q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__)
),
callers AS (
  SELECT IFF(time_known, 'CALLER', 'UNKNOWN_TIME') AS row_kind, user_name, role_name, hostnames,
         COUNT(DISTINCT query_id) AS calls,
         COUNT(DISTINCT IFF(status = 'Deny', query_id, NULL)) AS denied_calls,
         SUM(COALESCE(sent_bytes, 0)) AS sent_bytes,
         SUM(COALESCE(received_bytes, 0)) AS received_bytes,
         CAST(NULL AS NUMBER) AS billed_transfer_bytes,
         MIN(start_time) AS first_seen, MAX(start_time) AS last_seen
  FROM j
  GROUP BY 1, 2, 3, 4
),
tie AS (
  SELECT 'TIE_OUT' AS row_kind, CAST(NULL AS VARCHAR) AS user_name, CAST(NULL AS VARCHAR) AS role_name,
         'EXTERNAL_ACCESS transfer billed (DATA_TRANSFER_HISTORY)' AS hostnames,
         CAST(NULL AS BIGINT) AS calls, CAST(NULL AS BIGINT) AS denied_calls,
         CAST(NULL AS NUMBER) AS sent_bytes,
         CAST(NULL AS NUMBER) AS received_bytes,
         SUM(TRY_TO_NUMBER(TO_VARCHAR(bytes_transferred))) AS billed_transfer_bytes,
         MIN(start_time) AS first_seen, MAX(start_time) AS last_seen
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
  WHERE transfer_type = 'EXTERNAL_ACCESS'
    AND start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
allrows AS (
  SELECT * FROM callers
  UNION ALL
  SELECT * FROM tie
),
s AS (
  SELECT a.*, u.user_id, a.sent_bytes / POWER(1024, 2) AS sent_mb
  FROM allrows a
  LEFT JOIN sf_sec_users u ON u.user_name = a.user_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, row_kind, user_id, user_name, role_name, hostnames,
       calls, denied_calls, sent_bytes, received_bytes, billed_transfer_bytes, first_seen, last_seen,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(row_kind = 'CALLER' AND denied_calls > 0, denied_calls || ' denied calls', NULL),
         IFF(row_kind = 'CALLER' AND sent_mb >= :warn_sent_mb, ROUND(sent_mb) || ' MB sent', NULL),
         IFF(row_kind = 'UNKNOWN_TIME', 'query no longer in QUERY_HISTORY', NULL),
         IFF(row_kind = 'TIE_OUT', 'context only: billed transfer, not bytes sent', NULL)), '; ') AS reasons,
       IFF(row_kind = 'UNKNOWN_TIME', 'query_not_in_history', NULL) AS not_assessed_reason,
       CASE
         WHEN row_kind = 'UNKNOWN_TIME' THEN 'NOT_ASSESSED'
         WHEN row_kind = 'CALLER' AND (denied_calls >= :crit_denied OR sent_mb >= :crit_sent_mb) THEN 'CRITICAL'
         WHEN row_kind = 'CALLER' AND (denied_calls > 0 OR sent_mb >= :warn_sent_mb) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END,
         sent_bytes DESC NULLS LAST
