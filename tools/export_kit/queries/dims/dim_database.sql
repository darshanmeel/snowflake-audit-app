-- One row per live database: the base a "N of M databases" count is measured against.
SELECT __ACCOUNT_ID__ AS account_id, database_name, TO_VARCHAR(database_id) AS database_id
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES
WHERE deleted IS NULL
