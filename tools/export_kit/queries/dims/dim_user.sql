-- One row per live user: the base a "N of M users" count is measured against.
SELECT __ACCOUNT_ID__ AS account_id, name AS user_name, TO_VARCHAR(user_id) AS user_id
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
WHERE deleted_on IS NULL
