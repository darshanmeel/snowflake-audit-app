-- The INFORMATION_SCHEMA fallback's query feed, shared by the fallback checks: the result of
-- common/is_query_history_feed.sql, which the export runs once before the checks.
is_query_history AS (
  SELECT * FROM TABLE(RESULT_SCAN(__IS_QUERY_HISTORY_ID__))
)
