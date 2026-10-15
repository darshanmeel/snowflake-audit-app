-- query_id: sf_storage_clustering_key_mismatch
-- title: Clustered tables filtered on columns that are not the clustering key
-- domain: storage   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_share_pct (default 50) share pct: the top filter column must account for at least this
--   share of the table's query time to count; :warn_usd (default 25) usd: at or above this the row
--   reads WARN; :crit_usd (default 250) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live clustered table that spent automatic clustering credits in the window.
--   top_filter_column is the column queries filtered or joined on that carries the most query time,
--   top_filter_share_pct is that time as a share of all query time on the table, and key_matches says
--   whether the clustering key includes that column. est_clustering_usd_list is the upkeep of the table;
--   not all of it is waste, a mismatch only says the key may not match how the table is read.
-- healthy: status = OK when the key includes the main filter column, no single column dominates, or
--   upkeep is under warn_usd.
-- investigate_if: WARN when the top filter column has min_share_pct or more of the query time, is not in
--   the key and upkeep is warn_usd or more; CRITICAL at crit_usd. A table with no measured reads reads
--   NOT_ASSESSED.
-- actions: 1) look at the WHERE and JOIN columns of the table's heaviest queries (free); 2) recluster on
--   the column that is really filtered (ALTER TABLE ... CLUSTER BY) or drop the key if the table is barely
--   read (config); 3) suspend reclustering meanwhile to stop the spend (config).
-- next: sf_storage_clustering_value
-- empty_if: view_missing, no_activity, ingestion_lag
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the upkeep cannot be
--   priced; no_reads_measured: no query pruning rows for the table in the window, so its filter columns
--   are not known
-- caveats: pruning views lag up to 4 hours, keep only the 1,000 longest scans per query and skip hybrid
--   tables. A query that filters on several columns counts for each, so column shares can add to more
--   than 100. Exec time is shown in hours and is not priced, as warehouse spend is counted elsewhere.
--   The clustering key text is not stored, only whether it matches.
WITH ach AS (
  SELECT table_id, MAX(database_name || '.' || schema_name || '.' || table_name) AS table_fqn_hist,
         SUM(credits_used) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
  HAVING SUM(credits_used) > 0
),
-- Column rows are collapsed to one row per table and column before the join to credits.
col AS (
  SELECT table_id, UPPER(column_name) AS column_name,
         SUM(aggregate_query_execution_time) AS exec_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__
    AND UPPER(access_type) IN ('WHERE', 'JOIN') AND column_name IS NOT NULL
  GROUP BY table_id, UPPER(column_name)
),
topcol AS (
  SELECT table_id, MAX_BY(column_name, exec_ms) AS top_filter_column, MAX(exec_ms) AS top_exec_ms
  FROM col GROUP BY table_id
),
tq AS (
  SELECT table_id, SUM(aggregate_query_execution_time) AS exec_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__
  GROUP BY table_id
),
t AS (
  SELECT tb.table_id, tb.table_catalog || '.' || tb.table_schema || '.' || tb.table_name AS table_fqn,
         ach.credits, ach.credits * __CREDIT_PRICE__ AS usd,
         c.top_filter_column, c.top_exec_ms / 3600000 AS top_filter_hours,
         q.exec_ms / 3600000 AS table_query_hours,
         LEAST(100, 100 * c.top_exec_ms / NULLIF(q.exec_ms, 0)) AS top_filter_share_pct,
         -- Match on identifier boundaries so ID does not match inside USER_ID; $ is left out so it is never a regex anchor.
         CASE WHEN c.top_filter_column IS NULL THEN NULL
              WHEN REGEXP_LIKE(c.top_filter_column, '[A-Z_][A-Z0-9_]*')
                THEN REGEXP_LIKE(UPPER(tb.clustering_key), '.*(^|[^A-Z0-9_])' || c.top_filter_column || '($|[^A-Z0-9_]).*')
              ELSE POSITION(c.top_filter_column IN UPPER(tb.clustering_key)) > 0 END AS key_matches
  FROM ach
  JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES tb ON tb.table_id = ach.table_id AND tb.deleted IS NULL
  LEFT JOIN topcol c ON c.table_id = ach.table_id
  LEFT JOIN tq q ON q.table_id = ach.table_id
  WHERE NULLIF(TRIM(tb.clustering_key), '') IS NOT NULL
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       table_fqn, TO_VARCHAR(table_id) AS table_id, credits AS clustering_credits,
       usd AS est_clustering_usd_list,
       top_filter_column, ROUND(top_filter_hours, 2) AS top_filter_hours,
       ROUND(table_query_hours, 2) AS table_query_hours,
       ROUND(top_filter_share_pct, 1) AS top_filter_share_pct, key_matches,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN top_filter_column IS NULL THEN 'No reads measured for this table'
            ELSE 'Most filtered column ' || top_filter_column || ' (' || ROUND(top_filter_share_pct)
                 || '% of query time) is ' || IFF(key_matches, '', 'not ') || 'in the clustering key' END AS waste_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN top_filter_column IS NULL THEN 'no_reads_measured' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR top_filter_column IS NULL THEN 'NOT_ASSESSED'
         WHEN NOT key_matches AND top_filter_share_pct >= :min_share_pct AND usd >= :crit_usd THEN 'CRITICAL'
         WHEN NOT key_matches AND top_filter_share_pct >= :min_share_pct AND usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
ORDER BY credits DESC
