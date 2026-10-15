-- query_id: sf_wh_last_activity
-- title: Warehouses with no recent activity
-- domain: compute   tier: standard
-- windowed: no
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- empty_if: role_cannot_see
-- reads: SHOW WAREHOUSES, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :lookback_days (default 365) days of history searched for the last activity, counted back
--   from the export date; :warn_idle_days (default 90) days with no activity at or above which the row
--   reads WARN; :min_age_days (default 30) age a never-used warehouse needs before it reads WARN;
--   :credits_days (default 30) days of compute credits summed into credits_last_30d
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse, listed now or billed in the lookback and since dropped.
--   A warehouse no longer in SHOW WAREHOUSES reads state DROPPED when a DROP_WAREHOUSE event is seen, else
--   NOT_IN_SHOW. last_query_time is the last statement that ran on the warehouse (QUERY_HISTORY rows
--   with a warehouse size; metadata and result-cache hits that never start it are left out, and so are
--   the audit's own queries). last_resume_time is the last RESUME_WAREHOUSE event, last_metered_time the
--   last hour with compute credits. last_activity_time is the latest of the three; activity_band buckets
--   the days since it. credits_last_30d is compute credits in the :credits_days (30) days before the export date.
-- healthy: status = OK when the warehouse ran, resumed or billed within :warn_idle_days days, or was
--   created under :min_age_days days ago
-- investigate_if: WARN when nothing ran, resumed or billed for :warn_idle_days days or more, or the
--   warehouse never did in the lookback and is older than :min_age_days days
-- actions: 1) check with the owner whether anything still points at the warehouse (free); 2) drop it, or
--   fold its users onto a shared warehouse, which also removes it from grants and monitors (config)
-- next: sf_wh_config_current, sf_wh_consolidation_candidates
-- not_assessed_reasons: not_in_show: the warehouse billed in the lookback but SHOW WAREHOUSES does not list
--   it and no drop event was seen, so the role may not see it
-- caveats: QUERY_HISTORY, WAREHOUSE_EVENTS_HISTORY and WAREHOUSE_METERING_HISTORY keep 365 days, so
--   'never' means none in the lookback, not never at all. Views lag 45 min (QUERY_HISTORY) to 3 h
--   (events, metering). SHOW WAREHOUSES lists only warehouses the role can see. Ids come from metering
--   or events history by name; a warehouse that never billed or logged an event shows its name as id.
--   Activity is matched by id, so a warehouse dropped and re-created under the same name starts fresh
--   and the old one is listed as DROPPED.
WITH __INCLUDE_warehouse_config__,
q AS (
  -- warehouse_size is NULL when the statement never ran on the warehouse
  SELECT warehouse_id, MAX(start_time) AS last_query_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL AND warehouse_size IS NOT NULL
    AND COALESCE(query_tag, '') <> __QUERY_SOURCE__
  GROUP BY 1
),
e AS (
  -- by id, so a warehouse dropped and re-created under the same name does not inherit the old one's activity
  SELECT warehouse_id, MAX_BY(warehouse_name, timestamp) AS warehouse_name,
         MAX(IFF(event_name = 'RESUME_WAREHOUSE', timestamp, NULL)) AS last_resume_time,
         MAX(IFF(event_name = 'DROP_WAREHOUSE', timestamp, NULL)) AS drop_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE timestamp >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
  GROUP BY 1
),
m AS (
  SELECT warehouse_id, MAX_BY(warehouse_name, start_time) AS warehouse_name,
         MAX(IFF(credits_used_compute > 0, start_time, NULL)) AS last_metered_time,
         SUM(IFF(start_time >= DATEADD(day, -:credits_days, __AS_OF_DATE__), credits_used_compute, 0)) AS credits_last_30d
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
base AS (
  -- warehouses listed now (the include falls back to the name as id when metering has none; try the
  -- newest id in events next), then billed ids SHOW no longer lists
  SELECT c.warehouse_name,
         COALESCE(TRY_TO_NUMBER(c.warehouse_id),
                  (SELECT MAX(x.warehouse_id) FROM e x WHERE x.warehouse_name = c.warehouse_name)) AS wid,
         c.warehouse_size, c.warehouse_state AS state, c.created_on, TRUE AS in_show
  FROM warehouse_config c
  UNION ALL
  SELECT m.warehouse_name, m.warehouse_id, NULL, NULL, NULL, FALSE
  FROM m
  -- no compute ever leaves out the CLOUD_SERVICES_ONLY pseudo warehouse
  WHERE m.last_metered_time IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM warehouse_config c WHERE TRY_TO_NUMBER(c.warehouse_id) = m.warehouse_id)
    AND NOT EXISTS (SELECT 1 FROM warehouse_config c
                    WHERE TRY_TO_NUMBER(c.warehouse_id) IS NULL AND c.warehouse_name = m.warehouse_name)
),
j AS (
  SELECT b.warehouse_name, COALESCE(TO_VARCHAR(b.wid), b.warehouse_name) AS warehouse_id,
         b.warehouse_size,
         CASE WHEN b.in_show THEN b.state WHEN e.drop_time IS NOT NULL THEN 'DROPPED' ELSE 'NOT_IN_SHOW' END AS state,
         b.created_on, b.in_show, e.drop_time,
         q.last_query_time, e.last_resume_time, m.last_metered_time, COALESCE(m.credits_last_30d, 0) AS credits_last_30d,
         -- GREATEST returns NULL if any input is NULL, so pick from the non-NULL ones
         NULLIF(GREATEST(COALESCE(q.last_query_time, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(e.last_resume_time, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(m.last_metered_time, '1970-01-01'::TIMESTAMP_LTZ)),
                '1970-01-01'::TIMESTAMP_LTZ) AS last_activity_time
  FROM base b
  LEFT JOIN q ON q.warehouse_id = b.wid
  LEFT JOIN e ON e.warehouse_id = b.wid
  LEFT JOIN m ON m.warehouse_id = b.wid
),
s AS (
  SELECT j.*,
         DATEDIFF(day, last_activity_time, __AS_OF_DATE__) AS days_since_activity,
         DATEDIFF(day, created_on, __AS_OF_DATE__) AS age_days
  FROM j
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, warehouse_size AS size,
       state, created_on, last_query_time, last_resume_time, last_metered_time, last_activity_time,
       days_since_activity,
       CASE WHEN last_activity_time IS NULL THEN 'never'
            WHEN days_since_activity < 30 THEN '<30'
            WHEN days_since_activity < 90 THEN '30-89'
            WHEN days_since_activity < 180 THEN '90-179'
            ELSE '180+' END AS activity_band,
       credits_last_30d,
       CASE WHEN state = 'DROPPED' THEN 'Dropped ' || TO_VARCHAR(drop_time::DATE)
            WHEN state = 'NOT_IN_SHOW' THEN 'Billed in the lookback but not listed by SHOW WAREHOUSES'
            WHEN last_activity_time IS NULL AND age_days < :min_age_days THEN 'Created ' || age_days || ' days ago, not used yet'
            WHEN last_activity_time IS NULL THEN 'No query, resume or billing in the last ' || :lookback_days || ' days'
            ELSE 'Last active ' || days_since_activity || ' days ago' END AS finding,
       IFF(state = 'NOT_IN_SHOW', 'not_in_show', NULL) AS not_assessed_reason,
       CASE WHEN state = 'NOT_IN_SHOW' THEN 'NOT_ASSESSED'
            WHEN state = 'DROPPED' THEN 'OK'
            WHEN days_since_activity >= :warn_idle_days THEN 'WARN'
            WHEN last_activity_time IS NULL AND COALESCE(age_days, :min_age_days) >= :min_age_days THEN 'WARN'
            ELSE 'OK' END AS status
FROM s
ORDER BY IFF(status = 'WARN', 0, 1), days_since_activity DESC NULLS FIRST, warehouse_name
