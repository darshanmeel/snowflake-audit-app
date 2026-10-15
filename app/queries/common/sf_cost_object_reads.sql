-- Queries that read each object in the window, directly or through a view, from ACCESS_HISTORY
-- (Enterprise edition). Used to ask whether a serverless feature is paid for on an object nobody reads.
sf_cost_object_reads AS (
  SELECT f.value:"objectId"::NUMBER AS object_id,
         COUNT(DISTINCT ah.query_id) AS read_queries,
         COUNT(DISTINCT ah.user_name) AS read_users,
         MAX(ah.query_start_time) AS last_read_at
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(input => ARRAY_CAT(COALESCE(ah.direct_objects_accessed, ARRAY_CONSTRUCT()),
                                          COALESCE(ah.base_objects_accessed, ARRAY_CONSTRUCT()))) f
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
  GROUP BY 1
)
