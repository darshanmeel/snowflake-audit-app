-- One six-hour slice of the INFORMATION_SCHEMA fallback's query feed. The export runs 28 slices at
-- once, each its own statement with its own timeout, before the checks; the fallbacks read them all
-- through RESULT_SCAN (common/is_query_history.sql and shims/QUERY_HISTORY.sql), so the slow table
-- function is called once per export, and a slow slice drops only its own six hours.
-- QUERY_HISTORY (the table function) keeps 7 days, returns at most 10,000 rows a call and shows only
-- the queries this role can see (its own, and those on warehouses it has MONITOR or OPERATE on).
-- The rows stay in Snowflake's result cache; the checks export only aggregates, never query text.
-- Bind values are left out. It has no warehouse id: the name stands in for it.
SELECT * EXCLUDE (bind_values), warehouse_name AS warehouse_id
FROM TABLE(__INFO_SCHEMA__.QUERY_HISTORY(END_TIME_RANGE_START => __SLICE_START__,
     END_TIME_RANGE_END => __SLICE_END__, RESULT_LIMIT => 10000))
