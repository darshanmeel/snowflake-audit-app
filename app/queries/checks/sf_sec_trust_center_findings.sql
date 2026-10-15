-- query_id: sf_sec_trust_center_findings
-- title: Open Trust Center findings by scanner and severity
-- domain: governance_access   tier: standard
-- entity: findings = scanner_id
-- windowed: no
-- reads: SNOWFLAKE.TRUST_CENTER.FINDINGS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; the SNOWFLAKE.TRUST_CENTER_VIEWER
--   application role
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one Trust Center scanner, from its latest finding: severity, how many entities
--   (users, roles, integrations ...) are at risk and the recommended fix. at_risk_entities is the raw
--   list Trust Center reports, cut to 2000 characters.
-- healthy: status = OK when the latest run of the scanner found nothing at risk or the severity is LOW.
-- investigate_if: WARN for MEDIUM findings with entities at risk; CRITICAL for HIGH or CRITICAL
--   findings with entities at risk.
-- actions: 1) follow the recommendation for each CRITICAL scanner (free); 2) enable the CIS Benchmarks
--   and Threat Intelligence packages in Trust Center so scanners keep running (config)
-- next: none
-- caveats: optional: SNOWFLAKE.TRUST_CENTER.FINDINGS exists only where Trust Center is available and
--   needs the TRUST_CENTER_VIEWER application role; without it this check fails and nothing else is
--   affected. Columns are read by name from each row so a changed schema degrades to NULLs; findings
--   reflect the last scanner run, not live state.
WITH f AS (
  SELECT o:SCANNER_ID::VARCHAR AS scanner_id,
         COALESCE(o:SCANNER_NAME::VARCHAR, o:SCANNER_SHORT_DESCRIPTION::VARCHAR, o:SCANNER_ID::VARCHAR) AS scanner_name,
         o:SCANNER_PACKAGE_NAME::VARCHAR AS scanner_package,
         UPPER(o:SEVERITY::VARCHAR) AS severity,
         COALESCE(TRY_TO_NUMBER(TO_VARCHAR(o:TOTAL_AT_RISK_COUNT)),
                  IFF(IS_ARRAY(o:AT_RISK_ENTITIES), ARRAY_SIZE(o:AT_RISK_ENTITIES), NULL), 0) AS at_risk_count,
         LEFT(TO_VARCHAR(o:AT_RISK_ENTITIES), 2000) AS at_risk_entities,
         COALESCE(o:RECOMMENDATION::VARCHAR, o:SUGGESTED_ACTION::VARCHAR) AS recommendation,
         o:IMPACT::VARCHAR AS impact,
         UPPER(COALESCE(o:STATE::VARCHAR, o:STATUS::VARCHAR, 'OPEN')) AS state,
         COALESCE(TRY_TO_TIMESTAMP_LTZ(TO_VARCHAR(o:UPDATED_ON)), TRY_TO_TIMESTAMP_LTZ(TO_VARCHAR(o:CREATED_ON))) AS finding_time
  FROM (SELECT OBJECT_CONSTRUCT(*) AS o FROM SNOWFLAKE.TRUST_CENTER.FINDINGS)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY scanner_id ORDER BY finding_time DESC NULLS LAST) = 1
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, scanner_id, scanner_name, scanner_package, severity,
       state, at_risk_count, at_risk_entities, impact, recommendation, finding_time,
       IFF(at_risk_count > 0, at_risk_count || ' at risk (' || COALESCE(severity, '?') || ')', NULL) AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN at_risk_count = 0 OR state IN ('RESOLVED', 'CLOSED', 'SUPPRESSED') THEN 'OK'
         WHEN severity IN ('CRITICAL', 'HIGH') THEN 'CRITICAL'
         WHEN severity = 'MEDIUM' THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, at_risk_count DESC
