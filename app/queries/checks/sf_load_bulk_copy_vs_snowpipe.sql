-- query_id: sf_load_bulk_copy_vs_snowpipe
-- title: Frequent small COPY loads that Snowpipe could run for less (estimate)
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- money: est_saving_usd_list
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_copies_per_day (default 24) COPY statements per active day at or above which a load
--   counts as frequent; :max_median_mb (default 100) median MB read per COPY at or under which a load
--   counts as small; :snowpipe_credits_per_gb (default 0.0037) Snowpipe's credits per GB ingested (the
--   Service Consumption Table rate since December 2025); :uncompressed_ratio (default 4) how many times
--   bigger the files are uncompressed, since Snowpipe bills text files on their uncompressed size;
--   :warn_credits (default 5) estimated credits saved at or above which the row reads WARN;
--   :crit_credits (default 50) the same that reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. The saving is an estimate on two weak signals: the
--   warehouse time of the COPY statements, and the GB they read times an assumed compression ratio.
-- not_assessed_reasons: unknown_size: a frequent, small load runs on a warehouse whose size or type has no
--   fixed hourly rate (adaptive), or that SHOW WAREHOUSES does not list, so its COPY time cannot be priced
-- read_this: one row = one warehouse and user that ran COPY INTO a table in the window. copy_shapes counts
--   its distinct statement shapes (query_parameterized_hash, never the text). copies_per_day is per day
--   it ran;
--   median_mb is the bytes one COPY read. wh_credits prices the COPY run time at the warehouse's credits
--   per hour; snowpipe_credits is what Snowpipe would bill for the same GB (times uncompressed_ratio).
--   est_saving_credits is the difference when it is positive; est_saving_usd_list prices it. It is an
--   ESTIMATE and a possible saving, never waste, and never added to the savings total. verdict:
--   snowpipe_fits (frequent and small), keep_copy. auto_suspend_s is the warehouse's setting now: with
--   auto-suspend off (0), moving the load saves nothing until the warehouse can suspend.
-- healthy: status = OK unless a frequent, small COPY load is estimated to cost warn_credits more on a
--   warehouse than on Snowpipe.
-- investigate_if: WARN when verdict = snowpipe_fits and est_saving_credits >= warn_credits; CRITICAL when
--   >= crit_credits.
-- actions: 1) move the load to a pipe with AUTO_INGEST on the same stage and file format (config);
--   2) or run it less often with more files per COPY (free); 3) after moving it, lower the
--   warehouse's auto-suspend if nothing else uses it (config)
-- next: sf_load_small_files, sf_pipe_cost_and_files, sf_wh_idle_minutes
-- caveats: heavy: reads QUERY_HISTORY for the window (period_days only), COPY statements only; only
--   aggregates leave Snowflake. Bytes are what the statement read from the stage (usually compressed).
--   wh_credits leaves out the warehouse's idle time and the 60 s minimum after a resume, which the idle
--   checks count; on a warehouse that stays up for other work, the run time is the most a move saves.
--   Priced at the warehouse's current size. COPY_HISTORY has no warehouse or statement id, so it is not
--   joined; sf_load_small_files has its files.
WITH __INCLUDE_warehouse_config__,
cp AS (
  SELECT warehouse_name, user_name, COALESCE(query_parameterized_hash, query_hash) AS shape,
         TO_DATE(start_time) AS d, execution_time, bytes_scanned, rows_inserted
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type = 'COPY' AND warehouse_id IS NOT NULL AND execution_status = 'SUCCESS'
),
g AS (
  SELECT warehouse_name, user_name, COUNT(DISTINCT shape) AS copy_shapes, COUNT(*) AS copies, COUNT(DISTINCT d) AS active_days,
         SUM(execution_time) / 1000 AS exec_s, MEDIAN(execution_time) / 1000 AS median_exec_s,
         SUM(bytes_scanned) / POWER(1024, 3) AS gb_read, MEDIAN(bytes_scanned) / POWER(1024, 2) AS median_mb,
         SUM(rows_inserted) AS rows_loaded
  FROM cp
  GROUP BY 1, 2
),
r AS (
  SELECT c.warehouse_id, g.warehouse_name, c.warehouse_size, c.credits_per_hour,
         CAST(COALESCE(c.auto_stop_minutes, 0) * 60 AS INTEGER) AS auto_suspend_s, g.user_name, g.copy_shapes, g.copies, g.active_days,
         ROUND(g.copies / NULLIF(g.active_days, 0), 1) AS copies_per_day,
         g.median_exec_s, g.exec_s, g.gb_read, g.median_mb, g.rows_loaded,
         g.exec_s / 3600 * c.credits_per_hour AS wh_credits,
         g.gb_read * :uncompressed_ratio * :snowpipe_credits_per_gb AS snowpipe_credits
  FROM g
  LEFT JOIN warehouse_config c ON c.warehouse_name = g.warehouse_name
),
f AS (
  SELECT r.*, GREATEST(wh_credits - snowpipe_credits, 0) AS est_saving_credits,
         IFF(copies_per_day >= :min_copies_per_day AND median_mb <= :max_median_mb, 'snowpipe_fits', 'keep_copy') AS verdict
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, COALESCE(warehouse_id, warehouse_name) AS warehouse_id,
       warehouse_name, warehouse_size, auto_suspend_s, user_name, copy_shapes, copies, active_days, copies_per_day,
       ROUND(median_exec_s, 1) AS median_exec_s, ROUND(exec_s / 3600, 2) AS exec_hours,
       ROUND(gb_read, 3) AS gb_read, ROUND(median_mb, 2) AS median_mb, rows_loaded,
       wh_credits, snowpipe_credits, est_saving_credits,
       IFF(verdict = 'snowpipe_fits', est_saving_credits * __CREDIT_PRICE__, NULL) AS est_saving_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       'estimate' AS estimate_basis, verdict,
       CASE WHEN verdict = 'snowpipe_fits' AND credits_per_hour IS NULL THEN 'unknown_size' END AS not_assessed_reason,
       CASE
         WHEN verdict = 'snowpipe_fits' AND credits_per_hour IS NULL THEN 'NOT_ASSESSED'
         WHEN verdict = 'snowpipe_fits' AND est_saving_credits >= :crit_credits THEN 'CRITICAL'
         WHEN verdict = 'snowpipe_fits' AND est_saving_credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY IFF(verdict = 'snowpipe_fits', est_saving_credits, 0) DESC, copies DESC, warehouse_name
