-- Current table id of each live table by full name, for dynamic tables whose refresh history
-- carries names only. Dropped tables have no id here, so their rows keep the name alone.
sf_dt_dim AS (
  SELECT table_catalog || '.' || table_schema || '.' || table_name AS dt_full_name,
         MAX(TO_VARCHAR(table_id)) AS dt_id, MAX(table_owner) AS owner
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  GROUP BY 1
)
