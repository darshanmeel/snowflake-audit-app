-- query_id: sf_sec_trust_center_finding_age
-- title: Trust Center findings left open: age and time to resolve by severity
-- domain: governance_access   tier: standard
-- entity: scanner packages = scanner_package_id, severity
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TRUST_CENTER_FINDINGS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (a SECURITY_VIEWER database role may also work; the docs name none)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :crit_open_days (default 14) days: a HIGH or CRITICAL finding open longer flags CRITICAL;
--   :warn_open_days (default 30) days: a MEDIUM finding open longer flags WARN
-- empty_if: view_missing
-- not_assessed_reasons: scanners_not_enabled: the view holds no finding at all, so no scanner package has
--   run in this account
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Counts assume one row per finding; the docs do not say whether
--   a state change adds a row, and ID is the account's identifier, not the finding's.
-- read_this: one row = one scanner package x severity. open_findings and oldest_open_days say what is still
--   open, resolved_in_window and median_days_to_resolve how fast findings are closed. It complements
--   sf_sec_trust_center_findings, which shows the latest detail per scanner and needs the
--   TRUST_CENTER_VIEWER application role.
-- healthy: status = OK when no HIGH or CRITICAL finding is open longer than :crit_open_days and no MEDIUM
--   finding longer than :warn_open_days.
-- investigate_if: CRITICAL when a HIGH or CRITICAL finding is open longer than :crit_open_days; WARN when a
--   MEDIUM finding is open longer than :warn_open_days.
-- actions: 1) open the scanner in Trust Center and follow its fix for the oldest findings (free); 2) assign
--   an owner and a target date per severity (free); 3) enable the CIS Benchmarks package if no scanner
--   runs (config)
-- next: sf_sec_trust_center_findings
-- caveats: The view has no scanner name and no entities: names and entity lists are in Trust Center. Zero
--   rows in the whole view means no scanner package runs and reads NOT_ASSESSED, never clean. Counts assume one row per finding. Ages count
--   from the finding's creation to the export date. Lags up to 1 hour.
WITH f AS (
  SELECT scanner_package_id, UPPER(severity) AS severity, UPPER(state) AS state, created_on, updated_on,
         UPPER(state) LIKE 'RESOLVED%' AND updated_on >= DATEADD(day, -:period_days, __AS_OF_DATE__)
           AND updated_on < __AS_OF_DATE__ AS resolved_in_window
  FROM SNOWFLAKE.ACCOUNT_USAGE.TRUST_CENTER_FINDINGS
),
a AS (
  SELECT scanner_package_id, severity,
         COUNT_IF(state = 'OPEN') AS open_findings,
         MAX(IFF(state = 'OPEN', DATEDIFF(day, created_on, __AS_OF_DATE__), NULL)) AS oldest_open_days,
         COUNT_IF(resolved_in_window) AS resolved_in_window,
         MEDIAN(IFF(resolved_in_window, DATEDIFF(hour, created_on, updated_on) / 24.0, NULL)) AS median_days_to_resolve
  FROM f
  GROUP BY scanner_package_id, severity
),
s AS (
  SELECT a.*,
         COALESCE(severity IN ('CRITICAL', 'HIGH') AND oldest_open_days > :crit_open_days, FALSE) AS crit_old,
         COALESCE(severity = 'MEDIUM' AND oldest_open_days > :warn_open_days, FALSE) AS warn_old
  FROM a
),
r AS (
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, scanner_package_id, severity, open_findings,
         oldest_open_days, resolved_in_window, median_days_to_resolve,
         IFF(crit_old OR warn_old, open_findings || ' open, oldest ' || oldest_open_days || ' days', NULL) AS reasons,
         CAST(NULL AS VARCHAR) AS not_assessed_reason,
         CASE WHEN crit_old THEN 'CRITICAL' WHEN warn_old THEN 'WARN' ELSE 'OK' END AS status
  FROM s
  UNION ALL
  SELECT :period_days, __ACCOUNT_ID__, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER),
         CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR),
         'scanners_not_enabled', 'NOT_ASSESSED'
  FROM (SELECT 1 AS one) x
  WHERE NOT EXISTS (SELECT 1 FROM f)
)
SELECT * FROM r
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END,
         oldest_open_days DESC NULLS LAST, scanner_package_id
