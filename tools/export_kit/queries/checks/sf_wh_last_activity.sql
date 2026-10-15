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
WITH -- Current warehouse settings from the SHOW WAREHOUSES run just before (a check's `-- pre:` line),
-- with the numeric id taken from metering history by name. credits_per_hour is the Service
-- Consumption Table rate for the size, generation and resource constraint (rate_multiplier is its
-- ratio to a Gen1 standard warehouse of the same size; multi-cluster warehouses pay it per running
-- cluster; an estimate input, never billed spend). SHOW returns the counts and
-- auto_suspend as NUMBER, so they are cast, not TRY_TO_NUMBER'd (that takes text only).
-- An ADAPTIVE warehouse has no size, cluster counts or auto_suspend in SHOW, so those stay NULL.
warehouse_show AS (
  SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
-- Newer SHOW columns are read by key, since not every account returns them (is_interactive is AWS only).
warehouse_show_opt AS (
  SELECT r."name", r."type", r."size", r."state", r."min_cluster_count", r."max_cluster_count",
         r."auto_suspend", r."auto_resume", r."scaling_policy", r."resource_monitor", r."owner",
         r."enable_query_acceleration", r."updated_on", r."created_on",
         r.o:"resource_constraint"::VARCHAR AS "resource_constraint",
         r.o:"generation"::VARCHAR AS "generation",
         r.o:"is_interactive"::VARCHAR AS "is_interactive"
  FROM (SELECT w.*, OBJECT_CONSTRUCT(*) AS o FROM warehouse_show w) r
),
warehouse_config AS (
  SELECT COALESCE(TO_VARCHAR(ids.warehouse_id), s."name") AS warehouse_id,
         s."name" AS warehouse_name, s."type" AS warehouse_type, s."size" AS warehouse_size,
         s."state" AS warehouse_state,
         CAST(s."min_cluster_count" AS NUMBER) AS min_clusters,
         CAST(s."max_cluster_count" AS NUMBER) AS max_clusters,
         CAST(s."auto_suspend" AS NUMBER) / 60 AS auto_stop_minutes,
         s."auto_resume" AS auto_resume, s."scaling_policy" AS scaling_policy,
         s."resource_monitor" AS resource_monitor, s."owner" AS owner,
         s."enable_query_acceleration" AS query_acceleration, s."updated_on" AS updated_on,
         s."created_on" AS created_on,
         s."resource_constraint" AS resource_constraint,
         CASE WHEN UPPER(s."type") = 'ADAPTIVE' THEN 'ADAPTIVE'
              WHEN UPPER(s."type") = 'SNOWPARK-OPTIMIZED' THEN 'SNOWPARK_OPTIMIZED'
              WHEN UPPER(COALESCE(s."resource_constraint", '')) = 'STANDARD_GEN_2'
                   OR s."generation" = '2' THEN 'GEN2'
              ELSE 'GEN1' END AS warehouse_generation,
         CASE UPPER(REPLACE(s."size", '-', ''))
           WHEN 'XSMALL' THEN 1 WHEN 'SMALL' THEN 2 WHEN 'MEDIUM' THEN 4 WHEN 'LARGE' THEN 8
           WHEN 'XLARGE' THEN 16 WHEN '2XLARGE' THEN 32 WHEN 'XXLARGE' THEN 32
           WHEN '3XLARGE' THEN 64 WHEN 'XXXLARGE' THEN 64 WHEN '4XLARGE' THEN 128
           WHEN '5XLARGE' THEN 256 WHEN '6XLARGE' THEN 512
         END * s.rate_multiplier AS credits_per_hour,
         s.rate_multiplier
  FROM (
    -- Multipliers from Tables 1(b) to 1(d) of the Service Consumption Table (Gen2 is 1.25 on Azure,
    -- 1.35 elsewhere; Snowpark-optimized by resource constraint; interactive 0.6).
    SELECT r.*, CASE
      -- adaptive warehouses have no fixed hourly rate: unknown, never a size-based guess
      WHEN UPPER(r."type") = 'ADAPTIVE' THEN CAST(NULL AS DOUBLE)
      WHEN UPPER(r."type") = 'SNOWPARK-OPTIMIZED' THEN
        -- MEMORY_16X is the documented default for Snowpark-optimized (CREATE WAREHOUSE)
        CASE UPPER(COALESCE(r."resource_constraint", 'MEMORY_16X'))
          WHEN 'MEMORY_1X_X86' THEN 1.1 WHEN 'MEMORY_16X' THEN 1.5 WHEN 'MEMORY_16X_X86' THEN 1.5625
          WHEN 'MEMORY_64X' THEN 1.875 WHEN 'MEMORY_64X_X86' THEN 2.0 ELSE 1.0 END
      WHEN UPPER(r."type") = 'INTERACTIVE' OR LOWER(r."is_interactive") IN ('true', 'y') THEN 0.6
      WHEN UPPER(COALESCE(r."resource_constraint", '')) = 'STANDARD_GEN_2' OR r."generation" = '2'
        THEN IFF(__CLOUD__ = 'AZURE', 1.25, 1.35)
      ELSE 1.0 END AS rate_multiplier
    FROM warehouse_show_opt r
  ) s
  LEFT JOIN (
    SELECT warehouse_name, MAX(warehouse_id) AS warehouse_id
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD(day, -400, __AS_OF_DATE__)
    GROUP BY warehouse_name
  ) ids ON ids.warehouse_name = s."name"
),
q AS (
  -- warehouse_size is NULL when the statement never ran on the warehouse
  SELECT warehouse_id, MAX(start_time) AS last_query_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL AND warehouse_size IS NOT NULL
    AND COALESCE(query_tag, '') <> 'crosshire-audit'
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
