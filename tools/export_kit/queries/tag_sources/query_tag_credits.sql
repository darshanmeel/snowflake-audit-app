-- windowed: yes
-- Exact attributed compute credits per warehouse and query tag (QUERY_ATTRIBUTION_HISTORY). A query with
-- no tag is left out here: it is whatever the warehouse total leaves over.
SELECT :period_days AS window_days, TO_VARCHAR(warehouse_id) AS warehouse_id,
       TRIM(query_tag) AS query_tag, SUM(credits_attributed_compute) AS credits, COUNT(*) AS statements
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  AND NULLIF(TRIM(query_tag), '') IS NOT NULL
GROUP BY TO_VARCHAR(warehouse_id), TRIM(query_tag)
