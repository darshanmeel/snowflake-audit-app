-- query_id: sf_acct_parameters_posture
-- title: Account parameters that guard cost, reliability and data recovery
-- domain: governance_access   tier: standard
-- entity: parameters = parameter
-- windowed: no
-- pre: SHOW PARAMETERS IN ACCOUNT
-- reads: SHOW PARAMETERS IN ACCOUNT
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :max_statement_timeout_s (default 28800) statement timeout s: limit above which the row
--   flags; :max_retention_days (default 30) retention days: limit above which the row flags
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account parameter that shapes runaway cost, pipeline reliability or recovery
--   (the security parameters are in sf_sec_account_security_settings). value / default_value / level
--   come from SHOW PARAMETERS (level empty = still the default). verdict explains the rule; recommended
--   is the value this check expects. Warehouse, user and object settings can override the account
--   value.
-- healthy: status = OK when the parameter has a safe value.
-- investigate_if: WARN when STATEMENT_TIMEOUT_IN_SECONDS is 0 or above max_statement_timeout_s (the
--   2-day default included), STATEMENT_QUEUED_TIMEOUT_IN_SECONDS is 0, DATA_RETENTION_TIME_IN_DAYS is 0
--   or above max_retention_days, MIN_DATA_RETENTION_TIME_IN_DAYS is 0, MAX_DATA_EXTENSION_TIME_IN_DAYS
--   is under 14, USE_CACHED_RESULT is off, SUSPEND_TASK_AFTER_NUM_FAILURES is 0, LOG_LEVEL /
--   TRACE_LEVEL are verbose at account level, AUTOCOMMIT is off, nondeterministic MERGE errors are off,
--   OAuth may use privileged roles, or cross-region Cortex is on; CRITICAL when both statement timeouts
--   are 0.
-- actions: 1) ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = <hours of your longest job> and set
--   tighter values per warehouse (config); 2) set MIN_DATA_RETENTION_TIME_IN_DAYS = 1 so nobody can
--   switch off Time Travel (config); 3) keep LOG_LEVEL / TRACE_LEVEL at WARN / OFF at account level and
--   raise them per object while debugging, since event-table ingestion is billed (config).
-- next: none
-- caveats: a parameter missing on the edition or region shows NOT_ASSESSED. SHOW PARAMETERS returns
--   values as text; the defaults quoted are Snowflake's documented ones.
WITH p AS (
  SELECT UPPER("key") AS parameter, TO_VARCHAR("value") AS value, TO_VARCHAR("default") AS default_value,
         NULLIF(TO_VARCHAR("level"), '') AS level, "description" AS description
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
want AS (
  SELECT column1 AS parameter, column2 AS area, column3 AS recommended
  FROM VALUES
    ('STATEMENT_TIMEOUT_IN_SECONDS', 'cost', NULL),
    ('STATEMENT_QUEUED_TIMEOUT_IN_SECONDS', 'cost', '> 0'),
    ('USE_CACHED_RESULT', 'cost', 'TRUE'),
    ('DATA_RETENTION_TIME_IN_DAYS', 'recovery', NULL),
    ('MIN_DATA_RETENTION_TIME_IN_DAYS', 'recovery', '>= 1'),
    ('MAX_DATA_EXTENSION_TIME_IN_DAYS', 'reliability', '>= 14 (default)'),
    ('SUSPEND_TASK_AFTER_NUM_FAILURES', 'reliability', '> 0'),
    ('AUTOCOMMIT', 'reliability', 'TRUE'),
    ('ERROR_ON_NONDETERMINISTIC_MERGE', 'reliability', 'TRUE'),
    ('ERROR_ON_NONDETERMINISTIC_UPDATE', 'reliability', 'TRUE'),
    ('LOCK_TIMEOUT', 'reliability', '<= 43200 (default)'),
    ('LOG_LEVEL', 'cost', 'OFF / FATAL / ERROR / WARN'),
    ('TRACE_LEVEL', 'cost', 'OFF'),
    ('EVENT_TABLE', 'reliability', 'an event table (logs of UDFs, procedures, tasks)'),
    ('CORTEX_ENABLED_CROSS_REGION', 'governance', 'DISABLED unless approved'),
    ('OAUTH_ADD_PRIVILEGED_ROLES_TO_BLOCKED_LIST', 'governance', 'TRUE'),
    ('EXTERNAL_OAUTH_ADD_PRIVILEGED_ROLES_TO_BLOCKED_LIST', 'governance', 'TRUE'),
    ('TIMEZONE', 'reliability', 'one agreed zone (e.g. UTC)')
),
j AS (
  SELECT w.parameter, w.area,
         -- Thresholds come from params, so their recommended text is built here.
         COALESCE(w.recommended, CASE w.parameter
           WHEN 'STATEMENT_TIMEOUT_IN_SECONDS' THEN '1..' || :max_statement_timeout_s
           WHEN 'DATA_RETENTION_TIME_IN_DAYS' THEN '1..' || :max_retention_days END) AS recommended,
         p.value, p.default_value, p.level, p.description,
         UPPER(TRIM(p.value)) AS v, TRY_TO_NUMBER(p.value) AS n, p.parameter IS NOT NULL AS present
  FROM want w LEFT JOIN p ON p.parameter = w.parameter
),
v AS (
  SELECT j.*,
         CASE parameter
           WHEN 'STATEMENT_TIMEOUT_IN_SECONDS' THEN IFF(n = 0 OR n > :max_statement_timeout_s, 'WARN', 'OK')
           WHEN 'STATEMENT_QUEUED_TIMEOUT_IN_SECONDS' THEN IFF(n = 0, 'WARN', 'OK')
           WHEN 'USE_CACHED_RESULT' THEN IFF(v = 'FALSE', 'WARN', 'OK')
           WHEN 'DATA_RETENTION_TIME_IN_DAYS' THEN IFF(n = 0 OR n > :max_retention_days, 'WARN', 'OK')
           WHEN 'MIN_DATA_RETENTION_TIME_IN_DAYS' THEN IFF(n = 0, 'WARN', 'OK')
           WHEN 'MAX_DATA_EXTENSION_TIME_IN_DAYS' THEN IFF(n < 14, 'WARN', 'OK')
           WHEN 'SUSPEND_TASK_AFTER_NUM_FAILURES' THEN IFF(n = 0, 'WARN', 'OK')
           WHEN 'AUTOCOMMIT' THEN IFF(v = 'FALSE', 'WARN', 'OK')
           WHEN 'ERROR_ON_NONDETERMINISTIC_MERGE' THEN IFF(v = 'FALSE', 'WARN', 'OK')
           WHEN 'ERROR_ON_NONDETERMINISTIC_UPDATE' THEN 'OK'
           WHEN 'LOCK_TIMEOUT' THEN IFF(n > 43200, 'WARN', 'OK')
           WHEN 'LOG_LEVEL' THEN IFF(v IN ('TRACE', 'DEBUG', 'INFO'), 'WARN', 'OK')
           WHEN 'TRACE_LEVEL' THEN IFF(v IN ('ALWAYS', 'ON_EVENT'), 'WARN', 'OK')
           WHEN 'EVENT_TABLE' THEN 'OK'
           WHEN 'CORTEX_ENABLED_CROSS_REGION' THEN IFF(COALESCE(v, 'DISABLED') IN ('DISABLED', 'FALSE', ''), 'OK', 'WARN')
           WHEN 'OAUTH_ADD_PRIVILEGED_ROLES_TO_BLOCKED_LIST' THEN IFF(v = 'FALSE', 'WARN', 'OK')
           WHEN 'EXTERNAL_OAUTH_ADD_PRIVILEGED_ROLES_TO_BLOCKED_LIST' THEN IFF(v = 'FALSE', 'WARN', 'OK')
           WHEN 'TIMEZONE' THEN 'OK'
         END AS rule_status,
         CASE parameter
           WHEN 'STATEMENT_TIMEOUT_IN_SECONDS' THEN IFF(n = 0 OR n > :max_statement_timeout_s,
             'a runaway query can run ' || IFF(n = 0, 'for the 7-day maximum', ROUND(n / 3600, 1) || ' h') || ' before Snowflake stops it',
             'runaway queries stop after ' || ROUND(n / 3600, 1) || ' h')
           WHEN 'STATEMENT_QUEUED_TIMEOUT_IN_SECONDS' THEN IFF(n = 0,
             'queued queries wait forever, hiding an overloaded warehouse', 'queued queries give up after ' || n || ' s')
           WHEN 'USE_CACHED_RESULT' THEN IFF(v = 'FALSE', 'repeated queries recompute instead of using the free result cache', 'result cache on')
           WHEN 'DATA_RETENTION_TIME_IN_DAYS' THEN CASE WHEN n = 0 THEN 'new objects get no Time Travel: no UNDROP, no AT/BEFORE'
             WHEN n > :max_retention_days THEN n || ' days of Time Travel on every new object is costly storage'
             ELSE n || ' day(s) of Time Travel by default' END
           WHEN 'MIN_DATA_RETENTION_TIME_IN_DAYS' THEN IFF(n = 0, 'any owner can set retention to 0 and lose recovery', 'retention cannot drop below ' || n || ' day(s)')
           WHEN 'MAX_DATA_EXTENSION_TIME_IN_DAYS' THEN IFF(n < 14, 'streams on low-retention tables go stale sooner', 'streams get up to ' || n || ' days before going stale')
           WHEN 'SUSPEND_TASK_AFTER_NUM_FAILURES' THEN IFF(n = 0, 'a failing task retries forever and keeps billing', 'tasks suspend after ' || n || ' failures')
           WHEN 'AUTOCOMMIT' THEN IFF(v = 'FALSE', 'open transactions hold locks until clients commit', 'autocommit on')
           WHEN 'ERROR_ON_NONDETERMINISTIC_MERGE' THEN IFF(v = 'FALSE', 'MERGE with duplicate source keys silently picks a row', 'nondeterministic MERGE fails loudly')
           WHEN 'ERROR_ON_NONDETERMINISTIC_UPDATE' THEN IFF(v = 'FALSE', 'default: UPDATE with duplicate join rows picks one silently', 'nondeterministic UPDATE fails loudly')
           WHEN 'LOCK_TIMEOUT' THEN IFF(n > 43200, 'blocked statements wait over 12 h for locks', 'lock waits end after ' || ROUND(n / 3600, 1) || ' h')
           WHEN 'LOG_LEVEL' THEN IFF(v IN ('TRACE', 'DEBUG', 'INFO'), 'verbose logs from every UDF and procedure are ingested and billed', 'log level ' || COALESCE(v, 'unset'))
           WHEN 'TRACE_LEVEL' THEN IFF(v IN ('ALWAYS', 'ON_EVENT'), 'trace events from every UDF and procedure are ingested and billed', 'tracing ' || COALESCE(v, 'unset'))
           WHEN 'EVENT_TABLE' THEN IFF(NULLIF(v, '') IS NULL, 'no account event table: logs and traces are not kept', 'events go to ' || value)
           WHEN 'CORTEX_ENABLED_CROSS_REGION' THEN IFF(COALESCE(v, 'DISABLED') IN ('DISABLED', 'FALSE', ''),
             'Cortex calls stay in this region', 'Cortex prompts may be processed in ' || value)
           WHEN 'OAUTH_ADD_PRIVILEGED_ROLES_TO_BLOCKED_LIST' THEN IFF(v = 'FALSE', 'OAuth clients may use ACCOUNTADMIN / SECURITYADMIN', 'admin roles blocked for OAuth')
           WHEN 'EXTERNAL_OAUTH_ADD_PRIVILEGED_ROLES_TO_BLOCKED_LIST' THEN IFF(v = 'FALSE', 'External OAuth tokens may use ACCOUNTADMIN / SECURITYADMIN', 'admin roles blocked for External OAuth')
           WHEN 'TIMEZONE' THEN 'account time zone ' || COALESCE(value, 'unset')
         END AS verdict
  FROM j
),
both_unlimited AS (
  SELECT COUNT_IF(parameter = 'STATEMENT_TIMEOUT_IN_SECONDS' AND n = 0) > 0
         AND COUNT_IF(parameter = 'STATEMENT_QUEUED_TIMEOUT_IN_SECONDS' AND n = 0) > 0 AS flag
  FROM j
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       v.parameter, v.area, v.value, v.default_value, COALESCE(v.level, 'DEFAULT') AS level,
       v.recommended, v.verdict, v.description,
       CASE WHEN NOT v.present THEN 'parameter_not_shown' END AS not_assessed_reason,
       CASE
         WHEN NOT v.present THEN 'NOT_ASSESSED'
         WHEN b.flag AND v.parameter IN ('STATEMENT_TIMEOUT_IN_SECONDS', 'STATEMENT_QUEUED_TIMEOUT_IN_SECONDS') THEN 'CRITICAL'
         ELSE v.rule_status
       END AS status
FROM v CROSS JOIN both_unlimited b
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 3 ELSE 2 END, v.area, v.parameter
