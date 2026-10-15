-- The account; its display name is the account name. The loader
-- fills env from config/settings.yml's env_patterns.
SELECT __ACCOUNT_ID__ AS account_id, CURRENT_ACCOUNT_NAME() AS name,
       CAST(NULL AS VARCHAR) AS url
