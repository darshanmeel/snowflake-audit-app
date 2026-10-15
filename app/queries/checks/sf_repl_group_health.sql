-- query_id: sf_repl_group_health
-- title: Replication and failover groups: lag, failed refreshes and cost
-- domain: jobs_pipelines   tier: standard
-- entity: replication groups = group_name
-- windowed: yes
-- pre: SHOW REPLICATION GROUPS
-- reads: SHOW REPLICATION GROUPS, SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_REFRESH_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_lag_hours (default 24) lag hours: at or above this the row reads WARN; :crit_lag_hours
--   (default 72) lag hours: at or above this the row reads CRITICAL; :warn_usd (default 100) usd: at or
--   above this the row reads WARN; :crit_usd (default 1000) usd: at or above this the row reads
--   CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one replication or failover group held in this account (from SHOW), or one group
--   / legacy replicated database that only appears in the usage history. Refreshes run and are billed
--   on the SECONDARY side, so refreshes, lag_hours and credits are filled in the account that holds the
--   secondary; on the primary the row shows the schedule only. lag_hours = hours since the primary
--   snapshot of the last completed refresh (how old the secondary's data is).
-- healthy: status = OK when the secondary refreshed within warn_lag_hours, no refresh failed and the
--   credits stay under warn_usd.
-- investigate_if: WARN when a refresh failed, lag_hours >= warn_lag_hours, the secondary is suspended
--   or has no schedule, or credits cost >= warn_usd; CRITICAL when the latest refresh failed, lag_hours
--   >= crit_lag_hours, a secondary had no completed refresh in the window, or cost >= crit_usd.
-- actions: 1) read the failed refresh in REPLICATION_GROUP_REFRESH_HISTORY and fix it (free); 2) match
--   REPLICATION_SCHEDULE to the recovery point objective; a tighter schedule costs more (config); 3)
--   remove databases nobody needs from the group; replication bills credits plus data transfer per TB
--   (spend).
-- next: none
-- caveats: REPLICATION_GROUP_REFRESH_HISTORY and the usage views lag up to 3 hours. Data transfer bytes
--   are billed per TB outside the credit price, so est_*_usd_list covers credits only. The refresh
--   phase names and primary_snapshot_timestamp follow Snowflake's documented values; if the column is
--   empty, lag uses the refresh end time.
WITH g AS (
  SELECT "name" AS group_name, "type" AS group_type,
         LOWER(TO_VARCHAR("is_primary")) = 'true' AS is_primary,
         "primary" AS primary_group, "replication_schedule" AS replication_schedule,
         "secondary_state" AS secondary_state, "next_scheduled_refresh" AS next_scheduled_refresh,
         "object_types" AS object_types, "allowed_accounts" AS allowed_accounts, "owner" AS group_owner
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
  WHERE UPPER("account_locator") = CURRENT_ACCOUNT()
),
refresh AS (
  SELECT replication_group_name AS group_name,
         MAX(TO_VARCHAR(replication_group_id)) AS group_id,
         COUNT(*) AS refreshes,
         COUNT_IF(phase_name = 'COMPLETED') AS completed_refreshes,
         COUNT_IF(phase_name IN ('FAILED', 'CANCELED', 'CANCELLED')) AS failed_refreshes,
         MAX_BY(phase_name, start_time) AS last_phase,
         MAX(IFF(phase_name = 'COMPLETED', COALESCE(primary_snapshot_timestamp, end_time), NULL)) AS last_good_snapshot,
         AVG(IFF(phase_name = 'COMPLETED', DATEDIFF(second, start_time, end_time), NULL)) / 60 AS avg_refresh_minutes,
         MAX(IFF(phase_name = 'COMPLETED', DATEDIFF(second, start_time, end_time), NULL)) / 60 AS max_refresh_minutes
  FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_REFRESH_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
usage AS (
  SELECT 'GROUP' AS kind, replication_group_name AS group_name, SUM(credits_used) AS credits,
         SUM(bytes_transferred) AS bytes_transferred
  FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
  UNION ALL
  -- Legacy database-level replication (ALTER DATABASE ... ENABLE REPLICATION) bills here instead.
  SELECT 'DATABASE', database_name, SUM(credits_used), SUM(bytes_transferred)
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2
),
names AS (
  SELECT 'GROUP' AS kind, group_name FROM g
  UNION SELECT 'GROUP', group_name FROM refresh
  UNION SELECT kind, group_name FROM usage
),
j AS (
  SELECT n.kind, n.group_name, r.group_id, g.group_type, g.is_primary, g.primary_group,
         g.replication_schedule, g.secondary_state, g.next_scheduled_refresh, g.object_types,
         g.allowed_accounts, g.group_owner,
         -- A row with refresh history but no SHOW row is a secondary we can no longer see.
         (n.kind = 'GROUP' AND (g.is_primary = FALSE OR (g.group_name IS NULL AND r.group_name IS NOT NULL)))
           AS is_secondary,
         COALESCE(r.refreshes, 0) AS refreshes, COALESCE(r.completed_refreshes, 0) AS completed_refreshes,
         COALESCE(r.failed_refreshes, 0) AS failed_refreshes, r.last_phase, r.last_good_snapshot,
         r.avg_refresh_minutes, r.max_refresh_minutes,
         -- lag is read at the earlier of now and the export cut-off, so a rerun on an older as-of date and today's
         -- partial day agree on one "today"
         DATEDIFF(minute, r.last_good_snapshot, LEAST(CURRENT_TIMESTAMP(), CAST(__AS_OF_DATE__ AS TIMESTAMP))) / 60 AS lag_hours,
         COALESCE(u.credits, 0) AS credits, COALESCE(u.bytes_transferred, 0) AS bytes_transferred
  FROM names n
  LEFT JOIN g ON n.kind = 'GROUP' AND g.group_name = n.group_name
  LEFT JOIN refresh r ON n.kind = 'GROUP' AND r.group_name = n.group_name
  LEFT JOIN usage u ON u.kind = n.kind AND u.group_name = n.group_name
),
scored AS (
  SELECT j.*, credits * __CREDIT_PRICE__ AS usd,
         (is_secondary AND completed_refreshes = 0) AS no_refresh,
         (group_type IS NOT NULL AND NULLIF(TRIM(replication_schedule), '') IS NULL) AS g_sched_missing
  FROM j
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       kind, group_name, group_id, group_type, is_primary, is_secondary, primary_group,
       replication_schedule, secondary_state, next_scheduled_refresh, object_types, allowed_accounts,
       group_owner, refreshes, completed_refreshes, failed_refreshes, last_phase, last_good_snapshot,
       ROUND(lag_hours, 1) AS lag_hours, ROUND(avg_refresh_minutes, 1) AS avg_refresh_minutes,
       ROUND(max_refresh_minutes, 1) AS max_refresh_minutes, credits AS credits_used,
       bytes_transferred / POWER(1024, 3) AS gb_transferred,
       usd AS est_replication_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(no_refresh, 'no completed refresh in the window', NULL),
         IFF(last_phase IN ('FAILED', 'CANCELED', 'CANCELLED'), 'latest refresh ' || last_phase, NULL),
         IFF(failed_refreshes > 0, failed_refreshes || ' failed refreshes', NULL),
         IFF(lag_hours >= :warn_lag_hours, 'secondary is ' || ROUND(lag_hours) || ' h behind', NULL),
         IFF(is_secondary AND UPPER(secondary_state) = 'SUSPENDED', 'secondary suspended', NULL),
         IFF(is_secondary AND g_sched_missing, 'no refresh schedule', NULL),
         IFF(usd >= :warn_usd, ROUND(usd) || ' USD of replication credits', NULL)), '; ') AS reasons,
       CASE WHEN kind = 'GROUP' AND is_primary AND refreshes = 0 AND credits = 0
            THEN 'primary_side_refreshes_run_on_secondary'
            WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN no_refresh OR last_phase IN ('FAILED', 'CANCELED', 'CANCELLED')
           OR lag_hours >= :crit_lag_hours OR usd >= :crit_usd THEN 'CRITICAL'
         WHEN failed_refreshes > 0 OR lag_hours >= :warn_lag_hours OR usd >= :warn_usd
           OR (is_secondary AND (UPPER(secondary_state) = 'SUSPENDED' OR g_sched_missing)) THEN 'WARN'
         WHEN kind = 'GROUP' AND is_primary AND refreshes = 0 AND credits = 0 THEN 'NOT_ASSESSED'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, credits DESC
