-- query_id: sf_gov_dmf_expectation_failures
-- title: Data quality expectations that fail, or are never checked
-- domain: governance_access   tier: standard
-- windowed: yes
-- entity: tables = table_fqn
-- reads: SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS,
--   SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_EXPECTATIONS, SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_REFERENCES
-- requires: the SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER application role (for SNOWFLAKE.LOCAL); IMPORTED
--   PRIVILEGES on the SNOWFLAKE database; Enterprise Edition (data metric functions)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :crit_days (default 7) days an expectation has failed without a pass at or above which the row
--   reads CRITICAL
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one expectation on one data metric function (DMF) on one table. evaluations counts
--   the DMF runs in the window that tested it; violations those that broke it; eval_errors those where the
--   test itself failed (expectation_violated is NULL). latest_state is the last run's result (failing,
--   passing, error) and failing_days the days since it last passed (or since its first run in the window).
--   An expectation with no run in the window reads not_evaluated, and suspended when its DMF's schedule
--   is suspended. Only the expectation's name is kept, never its expression (it holds threshold values).
-- healthy: status = OK when the latest run passed.
-- investigate_if: WARN when the latest run failed or errored, or the DMF behind an expectation is
--   suspended; CRITICAL when it has failed for crit_days days or more without a pass.
-- actions: 1) fix the data or the pipeline behind the failing table, or the threshold if it is wrong
--   (free); 2) resume or re-create the suspended DMF association (free); 3) send failures somewhere people
--   look: an alert on SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS (config)
-- next: sf_gov_dmf_coverage, sf_gov_dmf_static_table_schedules
-- caveats: SNOWFLAKE.LOCAL needs the DATA_QUALITY_MONITORING_VIEWER application role, which IMPORTED
--   PRIVILEGES does not give; without it the check reads Not assessed. The views say whether a test failed, not whether anyone was told: DMF_REFERENCES'
--   notification status is reserved by Snowflake for future use, so alerting is not judged. Expectations on
--   views are listed like tables.
WITH ev AS (
  SELECT table_database || '.' || table_schema || '.' || table_name AS table_fqn, TO_VARCHAR(table_id) AS table_id,
         table_database AS database_name, metric_name, reference_id, expectation_id, MAX(expectation_name) AS expectation_name,
         COUNT(*) AS evaluations, COUNT_IF(expectation_violated) AS violations,
         COUNT_IF(expectation_violated IS NULL) AS eval_errors,
         MIN(measurement_time) AS first_run, MAX(measurement_time) AS last_run,
         MAX(IFF(expectation_violated = FALSE, measurement_time, NULL)) AS last_pass,
         MAX_BY(IFF(expectation_violated IS NULL, 'error', IFF(expectation_violated, 'failing', 'passing')),
                measurement_time) AS latest_state
  FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS
  WHERE measurement_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND measurement_time < __AS_OF_DATE__
  GROUP BY 1, 2, 3, 4, 5, 6
),
ref AS (
  SELECT ref_id, MAX(schedule_status) AS schedule_status
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_REFERENCES
  GROUP BY ref_id
),
dx AS (
  -- defined expectations, so one with no run in the window still shows
  SELECT ref_database_name || '.' || ref_schema_name || '.' || ref_entity_name AS table_fqn,
         ref_database_name AS database_name, metric_name, ref_id, expectation_id, expectation_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_METRIC_FUNCTION_EXPECTATIONS
),
j AS (
  SELECT COALESCE(ev.table_fqn, dx.table_fqn) AS table_fqn, ev.table_id, COALESCE(ev.database_name, dx.database_name) AS database_name,
         COALESCE(ev.metric_name, dx.metric_name) AS metric_name, COALESCE(ev.expectation_name, dx.expectation_name) AS expectation_name,
         COALESCE(ev.expectation_id, dx.expectation_id) AS expectation_id, ref.schedule_status,
         COALESCE(ev.evaluations, 0) AS evaluations, COALESCE(ev.violations, 0) AS violations,
         COALESCE(ev.eval_errors, 0) AS eval_errors, ev.first_run, ev.last_run, ev.last_pass,
         CASE WHEN ev.expectation_id IS NOT NULL THEN ev.latest_state
              WHEN UPPER(COALESCE(ref.schedule_status, '')) LIKE 'SUSPENDED%' THEN 'suspended'
              ELSE 'not_evaluated' END AS latest_state
  FROM ev
  FULL OUTER JOIN dx ON dx.expectation_id = ev.expectation_id AND dx.ref_id = ev.reference_id
  LEFT JOIN ref ON ref.ref_id = COALESCE(ev.reference_id, dx.ref_id)
),
f AS (
  SELECT j.*,
         IFF(latest_state = 'failing', DATEDIFF(day, COALESCE(last_pass, first_run), last_run), NULL) AS failing_days
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, table_fqn, table_id, database_name, metric_name,
       expectation_name, expectation_id, schedule_status, evaluations, violations, eval_errors, latest_state,
       failing_days, last_run, last_pass,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(latest_state = 'failing', 'failing for ' || failing_days || ' days', NULL),
         IFF(violations > 0, violations || ' of ' || evaluations || ' runs failed', NULL),
         IFF(eval_errors > 0, eval_errors || ' runs errored', NULL),
         IFF(latest_state = 'suspended', 'its DMF is suspended (' || LOWER(schedule_status) || ')', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE WHEN latest_state = 'failing' AND failing_days >= :crit_days THEN 'CRITICAL'
            WHEN latest_state IN ('failing', 'error', 'suspended') THEN 'WARN'
            ELSE 'OK' END AS status
FROM f
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, failing_days DESC NULLS LAST,
         violations DESC, table_fqn, expectation_name
