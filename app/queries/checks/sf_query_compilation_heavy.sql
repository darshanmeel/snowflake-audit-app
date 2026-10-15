-- query_id: sf_query_compilation_heavy
-- title: Statements dominated by compilation time
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_runs (default 20) runs: least a row needs before it can flag; :warn_compile_pct (default
--   50) compile pct: at or above this the row reads WARN; :min_compile_hours (default 1) compile hours:
--   least a row needs before it can flag; :crit_compile_hours (default 10) compile hours: at or above
--   this the row reads CRITICAL; :warn_cs_credits (default 5) cs credits: at or above this the row
--   reads WARN; :crit_cs_credits (default 50) cs credits: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement shape (query_parameterized_hash). compile_pct = compilation time
--   as a share of total elapsed time; cs_credits = cloud services credits its runs used (compilation,
--   metadata). High compile share means the optimizer, not the warehouse, is the bottleneck: huge SQL,
--   deep views, many small statements, or large IN lists.
-- healthy: status = OK when compilation is a small share of elapsed time or small in total
-- investigate_if: WARN when compile_pct >= warn_compile_pct and compile_hours >= min_compile_hours, or
--   cs_credits >= warn_cs_credits; CRITICAL when compile_hours >= crit_compile_hours or cs_credits >=
--   crit_cs_credits
-- actions: 1) replace row-by-row statements with set-based SQL or bulk COPY (free); 2) flatten deeply
--   nested views and generated SQL, move large IN lists to a join (free); 3) see
--   sf_cost_cloud_services_drivers for whether cloud services are billed at all (free)
-- next: none
-- caveats: cloud services credits are only billed above 10% of daily warehouse credits, so
--   est_billed_cs_usd_list is priced after that adjustment (the window's billed share of cloud services);
--   the thresholds are on cs_credits, which are before it.
WITH __INCLUDE_sf_cs_window_ratio__,
qh AS (
  SELECT query_parameterized_hash, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name, user_name,
         query_type, start_time, compilation_time, total_elapsed_time, credits_used_cloud_services,
         LENGTH(query_text) AS text_length
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_parameterized_hash IS NOT NULL AND compilation_time > 0
),
g AS (
  SELECT query_parameterized_hash, MODE(warehouse_name) AS warehouse_name, MAX(warehouse_id) AS warehouse_id,
         MODE(query_type) AS query_type, MODE(user_name) AS main_user_name, COUNT(*) AS runs,
         SUM(compilation_time) / 3600000 AS compile_hours,
         AVG(compilation_time) / 1000 AS avg_compile_s,
         100 * SUM(compilation_time) / NULLIF(SUM(total_elapsed_time), 0) AS compile_pct,
         SUM(credits_used_cloud_services) AS cs_credits,
         MAX(text_length) AS max_text_length
  FROM qh
  GROUP BY 1
  HAVING COUNT(*) >= :min_runs
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       query_parameterized_hash, query_type, main_user_name, runs, compile_hours, avg_compile_s, compile_pct,
       max_text_length, cs_credits, cs_credits * w.billed_ratio AS billed_cs_credits,
       cs_credits * w.billed_ratio * __CREDIT_PRICE__ AS est_billed_cs_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN compile_hours >= :crit_compile_hours OR cs_credits >= :crit_cs_credits THEN 'CRITICAL'
         WHEN (compile_pct >= :warn_compile_pct AND compile_hours >= :min_compile_hours)
           OR cs_credits >= :warn_cs_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g CROSS JOIN sf_cs_window w
ORDER BY compile_hours DESC
