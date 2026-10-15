-- query_id: sf_wh_resize_left_upsized
-- title: Warehouses resized up and left at the bigger size
-- domain: compute   tier: standard
-- entity: warehouses = warehouse
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 90) days of history the check looks at, counted back from the export
--   date; :min_days (default 7) days a warehouse must have stayed at its current size before it can
--   flag; :warn_usd (default 50) possible waste usd: at or above this the row reads WARN; :crit_usd
--   (default 500) possible waste usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse with compute in the window. baseline_size is the size it ran at
--   most hours before its current size began; current_size_since is when the current size began.
--   size_credit_ratio is current over baseline credits per hour. est_wasted_usd_list is the busy compute
--   since the resize times (1 - baseline / current rate): what the extra size cost if the same work
--   would have fit the old size. Busy = compute minus the idle sf_wh_idle_minutes already counts, so no
--   credit is waste twice. It is possible waste, not a bill line, and never added to spend.
-- healthy: status = OK when the warehouse is at or below its usual size, never resized in the window, or the
--   bigger size is new.
-- investigate_if: WARN when a warehouse has run above its baseline size for min_days or more and the
--   excess is >= warn_usd, CRITICAL at crit_usd. NOT_ASSESSED when there is no size history
--   or no baseline hours (see not_assessed_reason).
-- actions: 1) ask resized_by whether the bigger size was a one-off fix (free); 2) resize back and
--   watch queueing and spill for a week (config); 3) if the work really needs the size, keep it and
--   shorten AUTO_SUSPEND (spend).
-- next: none
-- empty_if: view_missing, role_cannot_see, no_activity, retention_window
-- not_assessed_reasons: unpriced: no credit price is available for the window; size_unknown: no size
--   record for this warehouse in the window or the 365 days before it; no_baseline_hours: no billed hours before the
--   current size began
-- caveats: size comes only from consistency events (read from 365 days before the window, so the size
--   at its start is known), so hours before a warehouse's first one are unknown and left out of the
--   baseline. Who resized is the latest resize or alter event in the day
--   before the change. Size rates are compared as ratios (X-Small 1 ... 6X-Large 512); a size name the
--   check does not know is left out. Convert-type changes are not read. The view lags up to 3 h.
WITH cons AS (
  SELECT warehouse_id, timestamp AS ts, MAX(size) AS size_name,
         MAX(CASE REPLACE(REPLACE(UPPER(size), '-', ''), ' ', '')
               WHEN 'XSMALL' THEN 1 WHEN 'SMALL' THEN 2 WHEN 'MEDIUM' THEN 4 WHEN 'LARGE' THEN 8
               WHEN 'XLARGE' THEN 16
               WHEN '2XLARGE' THEN 32 WHEN 'XXLARGE' THEN 32 WHEN 'X2LARGE' THEN 32
               WHEN '3XLARGE' THEN 64 WHEN 'XXXLARGE' THEN 64 WHEN 'X3LARGE' THEN 64
               WHEN '4XLARGE' THEN 128 WHEN 'X4LARGE' THEN 128
               WHEN '5XLARGE' THEN 256 WHEN 'X5LARGE' THEN 256
               WHEN '6XLARGE' THEN 512 WHEN 'X6LARGE' THEN 512 END) AS rate
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
  WHERE event_name = 'WAREHOUSE_CONSISTENT' AND size IS NOT NULL
    -- a year before the window too, so the size at the window's start is known
    AND timestamp >= DATEADD(day, -(:period_days + 365), __AS_OF_DATE__) AND timestamp < __AS_OF_DATE__
  GROUP BY warehouse_id, timestamp
),
known AS (
  SELECT * FROM cons WHERE rate IS NOT NULL
),
lg AS (
  SELECT k.*, LAG(rate) OVER (PARTITION BY warehouse_id ORDER BY ts) AS prev_rate
  FROM known k
),
seg AS (
  SELECT warehouse_id, ts AS from_ts,
         LEAD(ts) OVER (PARTITION BY warehouse_id ORDER BY ts) AS to_ts,
         rate, prev_rate, size_name
  FROM lg
  WHERE prev_rate IS NULL OR rate <> prev_rate
),
cur AS (
  -- a size that began before the window was not resized in it
  SELECT warehouse_id, from_ts AS stretch_start, rate AS current_rate,
         IFF(from_ts >= DATEADD(day, -:period_days, __AS_OF_DATE__), prev_rate, NULL) AS prev_rate,
         size_name AS current_size
  FROM seg
  WHERE to_ts IS NULL
),
wh AS (
  SELECT warehouse_id, MAX(warehouse_name) AS warehouse_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY warehouse_id
  HAVING SUM(credits_used_compute) > 0
),
hrs AS (
  SELECT w.warehouse_id, w.start_time, w.credits_used_compute AS credits, s.rate, s.size_name,
         -- the hour's idle exactly as sf_wh_idle_minutes counts it (settled hours with a query split)
         IFF(w.start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND w.credits_attributed_compute_queries IS NOT NULL,
             GREATEST(w.credits_used_compute - w.credits_attributed_compute_queries, 0), 0) AS idle_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
  LEFT JOIN seg s ON s.warehouse_id = w.warehouse_id AND w.start_time >= s.from_ts
    AND (s.to_ts IS NULL OR w.start_time < s.to_ts)
  WHERE w.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND w.start_time < __AS_OF_DATE__
),
pre AS (
  SELECT h.warehouse_id, h.rate, MAX(h.size_name) AS size_name, COUNT(*) AS hours_at_size
  FROM hrs h JOIN cur c ON c.warehouse_id = h.warehouse_id
  WHERE h.rate IS NOT NULL AND h.credits > 0 AND h.start_time < c.stretch_start
  GROUP BY h.warehouse_id, h.rate
),
modal AS (
  SELECT warehouse_id, rate AS baseline_rate, size_name AS baseline_size
  FROM (SELECT p.*, ROW_NUMBER() OVER (PARTITION BY warehouse_id ORDER BY hours_at_size DESC, rate) AS rn FROM pre p) r
  WHERE rn = 1
),
post AS (
  SELECT h.warehouse_id, SUM(h.credits) AS post_credits, SUM(h.credits - h.idle_credits) AS post_busy_credits
  FROM hrs h JOIN cur c ON c.warehouse_id = h.warehouse_id
  WHERE h.start_time >= c.stretch_start
  GROUP BY h.warehouse_id
),
who AS (
  SELECT warehouse_id, user_name, role_name
  FROM (
    SELECT e.warehouse_id, e.user_name, e.role_name,
           ROW_NUMBER() OVER (PARTITION BY e.warehouse_id ORDER BY e.timestamp DESC) AS rn
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY e
    JOIN cur c ON c.warehouse_id = e.warehouse_id
    WHERE e.event_name IN ('RESIZE_WAREHOUSE', 'ALTER_WAREHOUSE') AND e.user_name IS NOT NULL
      AND e.timestamp <= c.stretch_start AND e.timestamp > DATEADD(day, -1, c.stretch_start)
  ) r
  WHERE rn = 1
),
s AS (
  SELECT wh.warehouse_id, wh.warehouse_name, c.stretch_start, c.current_rate, c.prev_rate,
         c.current_size, m.baseline_rate, m.baseline_size, p.post_credits,
         DATEDIFF(day, c.stretch_start, __AS_OF_DATE__) AS days_at_size,
         wo.user_name AS resized_by, wo.role_name AS resized_by_role,
         -- NULL, not 0, on a row the status leaves NOT_ASSESSED
         CASE WHEN c.current_rate IS NULL THEN NULL
              WHEN m.baseline_rate IS NULL THEN IFF(c.prev_rate IS NULL OR c.current_rate <= c.prev_rate, 0, NULL)
              WHEN c.current_rate > m.baseline_rate THEN p.post_busy_credits * (1 - m.baseline_rate / c.current_rate)
              ELSE 0 END AS excess_credits
  FROM wh
  LEFT JOIN cur c ON c.warehouse_id = wh.warehouse_id
  LEFT JOIN modal m ON m.warehouse_id = wh.warehouse_id
  LEFT JOIN post p ON p.warehouse_id = wh.warehouse_id
  LEFT JOIN who wo ON wo.warehouse_id = wh.warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       COALESCE(warehouse_name, 'unknown') || ' (' || TO_VARCHAR(warehouse_id) || ')' AS warehouse,
       baseline_size, current_size, current_rate / NULLIF(baseline_rate, 0) AS size_credit_ratio,
       stretch_start AS current_size_since, days_at_size, post_credits AS credits_since_resize,
       excess_credits, resized_by, resized_by_role,
       excess_credits * __CREDIT_PRICE__ AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE
         WHEN current_rate IS NULL THEN 'size_unknown'
         WHEN prev_rate IS NULL THEN NULL
         WHEN baseline_rate IS NULL AND current_rate <= prev_rate THEN NULL
         WHEN baseline_rate IS NULL THEN 'no_baseline_hours'
         WHEN current_rate > baseline_rate AND days_at_size >= :min_days AND __CREDIT_PRICE__ IS NULL THEN 'unpriced'
       END AS not_assessed_reason,
       CASE
         WHEN current_rate IS NULL THEN 'NOT_ASSESSED'
         WHEN prev_rate IS NULL THEN 'OK'
         -- resized down at the window's start: nothing to judge as upsized
         WHEN baseline_rate IS NULL AND current_rate <= prev_rate THEN 'OK'
         WHEN baseline_rate IS NULL THEN 'NOT_ASSESSED'
         WHEN current_rate <= baseline_rate OR days_at_size < :min_days THEN 'OK'
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN excess_credits * __CREDIT_PRICE__ >= :crit_usd THEN 'CRITICAL'
         WHEN excess_credits * __CREDIT_PRICE__ >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY est_wasted_usd_list DESC NULLS LAST, warehouse
