-- The INFORMATION_SCHEMA fallback's query feed, shared by the fallback checks: the slices of
-- common/is_query_history_feed.sql that the export ran before the checks, one row per query id.
is_query_history AS (
  SELECT * FROM (__IS_QUERY_HISTORY_SCANS__)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY end_time DESC) = 1
)
