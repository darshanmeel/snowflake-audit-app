-- query_id: sf_cost_native_app_inventory
-- title: Installed Native Apps: owner, version, state and what each costs
-- domain: cost   tier: standard
-- entity: native apps = app_name
-- windowed: yes
-- pre: SHOW APPLICATIONS
-- reads: SHOW APPLICATIONS, SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; the role must be able to see the apps (SHOW APPLICATIONS
--   lists only apps the role has a privilege on)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_age_days (default 30) age days: an app younger than this is not flagged as unused
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The upgrade_state and disablement_reasons values are not listed in
--   the docs, so a failed upgrade is matched on the word FAIL and a disabled app on any reason text.
-- read_this: one row = one installed Native App (name). owner is the role that installed it; source_type and
--   version say where it came from. window_credits and active_days come from the app's own usage rows; an app
--   with no credits in the window may still run on your warehouses. A usage row with no matching app in SHOW
--   APPLICATIONS is listed as not assessed (the role cannot see the app).
-- healthy: status = OK when the app is used, new, or costs nothing in the window.
-- investigate_if: WARN when an app older than :min_age_days used no credits and holds no storage in the window, is
--   disabled, or its last upgrade failed; NOT_ASSESSED when the app is in usage but not in SHOW APPLICATIONS.
-- actions: 1) ask the owner whether the app is still used (free); 2) drop apps nobody uses so they stop holding
--   storage and compute pools (config); 3) look into a disabled or failed-upgrade app with its provider (free)
-- next: sf_cost_native_app_spend
-- not_assessed_reasons: not_in_show_applications: the app has usage rows but SHOW APPLICATIONS does not list it
--   (dropped, or the role has no privilege on it)
-- caveats: the credits are already inside the account's metering totals: a slice of spend, never an addition to
--   it. Listing fees charged by the provider are not included. APPLICATION_DAILY_USAGE_HISTORY lists apps with
--   credits only and lags about a day. Apps are matched to usage by name, so two installs with one name share
--   usage rows. Storage is a monthly figure kept apart from the window cost.
WITH shown AS (
  SELECT a."name" AS app_name, a."owner" AS owner, a."source_type" AS source_type, a."version" AS version,
         TRY_TO_NUMBER(TO_VARCHAR(a."patch")) AS patch, a."created_on" AS created_on,
         a."last_upgraded_on" AS last_upgraded_on, a."upgrade_state" AS upgrade_state,
         NULLIF(NULLIF(TO_VARCHAR(a."disablement_reasons"), ''), '[]') AS disablement_reasons
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) a
),
u AS (
  SELECT application_name AS app_name, MAX(application_id) AS application_id,
         SUM(COALESCE(credits_used, 0)) AS window_credits,
         COUNT_IF(COALESCE(credits_used, 0) > 0) AS active_days,
         AVG(storage_bytes) AS avg_storage_bytes
  FROM SNOWFLAKE.ACCOUNT_USAGE.APPLICATION_DAILY_USAGE_HISTORY
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY application_name
),
j AS (
  SELECT COALESCE(s.app_name, u.app_name) AS app_name, u.application_id, s.owner, s.source_type, s.version, s.patch,
         s.created_on, s.last_upgraded_on, s.upgrade_state, s.disablement_reasons,
         s.app_name IS NOT NULL AS in_show,
         COALESCE(u.window_credits, 0) AS window_credits, COALESCE(u.active_days, 0) AS active_days,
         u.avg_storage_bytes, DATEDIFF('day', s.created_on, __AS_OF_DATE__) AS age_days
  FROM shown s
  FULL OUTER JOIN u ON u.app_name = s.app_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       app_name || COALESCE(' (' || application_id || ')', '') AS app_name, owner, source_type, version, patch,
       created_on, age_days, last_upgraded_on, upgrade_state,
       disablement_reasons IS NOT NULL AS is_disabled,
       window_credits, active_days, avg_storage_bytes,
       window_credits * __CREDIT_PRICE__ AS est_within_usd_list,
       avg_storage_bytes / POWER(1024, 4) * __STORAGE_PRICE_TB_MONTH__ AS est_storage_usd_month,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(in_show AND age_days >= :min_age_days AND window_credits = 0 AND COALESCE(avg_storage_bytes, 0) = 0,
             'no credits or storage in the window', NULL),
         IFF(disablement_reasons IS NOT NULL, 'app is disabled', NULL),
         IFF(UPPER(COALESCE(upgrade_state, '')) LIKE '%FAIL%', 'last upgrade failed', NULL)), '; ') AS reasons,
       CASE WHEN NOT in_show THEN 'not_in_show_applications' END AS not_assessed_reason,
       CASE
         WHEN NOT in_show THEN 'NOT_ASSESSED'
         WHEN disablement_reasons IS NOT NULL OR UPPER(COALESCE(upgrade_state, '')) LIKE '%FAIL%' THEN 'WARN'
         WHEN age_days >= :min_age_days AND window_credits = 0 AND COALESCE(avg_storage_bytes, 0) = 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY IFF(status = 'OK', 1, 0), window_credits DESC, app_name
