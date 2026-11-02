-- query_id: sf_use_table_daily
-- title: Each busy table, day by day: reads, writes, DDL and rows changed
-- domain: storage   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30, capped at 90) days of history the check looks at, counted back from the export
--   date; :top_n (default 50) tables kept, ranked by distinct queries then DML rows over the window
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one of the :top_n busiest tables on one day, with zero-usage days included so a
--   chart has no gaps. rows_added / rows_removed / rows_updated / dml_rows come from TABLE_DML_HISTORY
--   (all editions). read_queries / write_queries / ddl_queries are distinct queries per day from
--   ACCESS_HISTORY (Enterprise and above) and readers / writers the distinct users behind them.
--   access_basis says which columns are real: access_history = all of them, dml_only = the query columns
--   are NULL (not 0) because ACCESS_HISTORY is empty, shown as a dash. table_rank 1 = busiest.
-- healthy: status is always OK: this is a trend series, not a finding. DML works on every edition, so the
--   check is never wholly NOT_ASSESSED.
-- investigate_if: never flags. Read a day with many write_queries or dml_rows against its neighbours to
--   find the load, backfill or rewrite behind a change in a table's size or cost.
-- actions: 1) open the table in Tables to see who reads and writes it (free); 2) check sf_use_table_churn
--   in Storage if dml_rows is large against the table's size (free); 3) find the job behind a write
--   spike (engineering).
-- next: none
-- empty_if: role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window (Standard edition or
--   no access), so reads, writes and DDL cannot be counted, only DML rows are shown
-- caveats: TABLE_DML_HISTORY lags up to 6 hours, so the last day can be short; it has no hybrid tables
--   and covers user DML plus Snowpipe; a missing view fails the check. Days run from the window start to
--   the day before the export date (no partial today). Ranking on Standard is by DML rows alone.
WITH __INCLUDE_sf_use_access_events__,
__INCLUDE_sf_storage_live_tables__,
days AS (
  SELECT DATEADD(day, -ROW_NUMBER() OVER (ORDER BY seq4()), __AS_OF_DATE__) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
),
win AS (
  SELECT d FROM days WHERE d >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__)
),
dml_d AS (
  SELECT table_id, DATE(start_time) AS usage_date,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(table_name) AS table_name,
         SUM(COALESCE(rows_added, 0)) AS rows_added, SUM(COALESCE(rows_removed, 0)) AS rows_removed,
         SUM(COALESCE(rows_updated, 0)) AS rows_updated
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
  WHERE start_time >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id, DATE(start_time)
),
ah_d AS (
  SELECT object_id AS table_id, usage_date, MAX(object_name) AS object_name,
         COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries,
         COUNT(DISTINCT IFF(kind = 'read', user_name, NULL)) AS readers,
         COUNT(DISTINCT IFF(kind = 'write', user_name, NULL)) AS writers
  FROM sf_use_access_events
  WHERE is_table_like AND object_id IS NOT NULL
    AND usage_date >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY object_id, usage_date
),
ah_seen AS (SELECT access_rows FROM sf_use_access_seen),
ah_tot AS (
  SELECT object_id AS table_id, COUNT(DISTINCT query_id) AS queries
  FROM sf_use_access_events
  WHERE is_table_like AND object_id IS NOT NULL
    AND usage_date >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY object_id
),
dml_tot AS (
  SELECT table_id, SUM(rows_added + rows_removed + rows_updated) AS dml_rows FROM dml_d WHERE table_id IS NOT NULL GROUP BY table_id
),
tot AS (
  SELECT COALESCE(a.table_id, m.table_id) AS table_id, COALESCE(a.queries, 0) AS queries,
         COALESCE(m.dml_rows, 0) AS dml_rows
  FROM ah_tot a
  FULL OUTER JOIN dml_tot m ON m.table_id = a.table_id
),
ranked AS (
  SELECT table_id, ROW_NUMBER() OVER (ORDER BY queries DESC, dml_rows DESC, table_id) AS table_rank FROM tot
),
top AS (SELECT table_id, table_rank FROM ranked WHERE table_rank <= :top_n),
daily AS (
  SELECT t.table_id, t.table_rank, w.d AS usage_date,
         COALESCE(m.rows_added, 0) AS rows_added, COALESCE(m.rows_removed, 0) AS rows_removed,
         COALESCE(m.rows_updated, 0) AS rows_updated,
         a.read_queries, a.write_queries, a.ddl_queries, a.readers, a.writers
  FROM top t
  CROSS JOIN win w
  LEFT JOIN dml_d m ON m.table_id = t.table_id AND m.usage_date = w.d
  LEFT JOIN ah_d a ON a.table_id = t.table_id AND a.usage_date = w.d
),
names AS (
  -- one name per table, fixed priority: live table, then DML names, then the ACCESS_HISTORY name
  SELECT t.table_id,
         COALESCE(l.database_name, d.database_name, NULLIF(SPLIT_PART(h.object_name, '.', 1), '')) AS database_name,
         COALESCE(l.schema_name, d.schema_name, NULLIF(SPLIT_PART(h.object_name, '.', 2), '')) AS schema_name,
         COALESCE(l.table_name, d.table_name, NULLIF(SPLIT_PART(h.object_name, '.', 3), '')) AS table_name
  FROM top t
  LEFT JOIN sf_storage_live_tables l ON l.table_id = t.table_id
  LEFT JOIN (SELECT table_id, MAX(database_name) AS database_name, MAX(schema_name) AS schema_name,
                    MAX(table_name) AS table_name FROM dml_d GROUP BY table_id) d ON d.table_id = t.table_id
  LEFT JOIN (SELECT table_id, MAX(object_name) AS object_name FROM ah_d GROUP BY table_id) h
         ON h.table_id = t.table_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, n.usage_date,
       m.database_name, m.schema_name,
       COALESCE(m.table_name, 'table (' || n.table_id || ')') AS table_name,
       n.table_id,
       COALESCE(m.database_name || '.' || m.schema_name || '.' || m.table_name,
                'table (' || n.table_id || ')') AS table_fqn,
       n.table_rank,
       n.rows_added, n.rows_removed, n.rows_updated,
       n.rows_added + n.rows_removed + n.rows_updated AS dml_rows,
       IFF(s.access_rows = 0, NULL, COALESCE(n.read_queries, 0)) AS read_queries,
       IFF(s.access_rows = 0, NULL, COALESCE(n.write_queries, 0)) AS write_queries,
       IFF(s.access_rows = 0, NULL, COALESCE(n.ddl_queries, 0)) AS ddl_queries,
       IFF(s.access_rows = 0, NULL, COALESCE(n.readers, 0)) AS readers,
       IFF(s.access_rows = 0, NULL, COALESCE(n.writers, 0)) AS writers,
       IFF(s.access_rows = 0, 'dml_only', 'access_history') AS access_basis,
       IFF(s.access_rows = 0, 'no_access_history', NULL) AS not_assessed_reason,
       'OK' AS status
FROM daily n
JOIN names m ON m.table_id = n.table_id
CROSS JOIN ah_seen s
ORDER BY n.table_rank, n.table_id, n.usage_date
