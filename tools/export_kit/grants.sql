CREATE ROLE IF NOT EXISTS AUDIT_ROLE;

-- The ACCOUNT_USAGE views: all of them.
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE AUDIT_ROLE;
-- Or, when IMPORTED PRIVILEGES is hard to get approved, these four read-only database roles instead.
-- They open about 225 of the checks; the rest read "the role can't see it" (the task checks need
-- TASK_VERSIONS, which none of the four opens).
--   GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER      TO ROLE AUDIT_ROLE;  -- cost and usage
--   GRANT DATABASE ROLE SNOWFLAKE.OBJECT_VIEWER     TO ROLE AUDIT_ROLE;  -- tables and objects
--   GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE AUDIT_ROLE;  -- query and access history, policies, tags
--   GRANT DATABASE ROLE SNOWFLAKE.SECURITY_VIEWER   TO ROLE AUDIT_ROLE;  -- logins, users, roles, grants

-- Account-level usage and billing history in the metering views.
GRANT MONITOR USAGE ON ACCOUNT TO ROLE AUDIT_ROLE;

-- Tasks and pipes: SHOW TASKS and the pipe checks list only what the role may monitor.
GRANT MONITOR EXECUTION ON ACCOUNT TO ROLE AUDIT_ROLE;

-- A small warehouse to run the export on.
CREATE WAREHOUSE IF NOT EXISTS AUDIT_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
GRANT USAGE ON WAREHOUSE AUDIT_WH TO ROLE AUDIT_ROLE;

-- SHOW WAREHOUSES lists only the warehouses the role has a privilege on. Grant MONITOR on each one
-- (repeat for every warehouse, and again whenever a new one is created).
GRANT MONITOR ON WAREHOUSE MY_WAREHOUSE TO ROLE AUDIT_ROLE;

-- Same for resource monitors (SHOW RESOURCE MONITORS).
GRANT MONITOR ON RESOURCE MONITOR MY_MONITOR TO ROLE AUDIT_ROLE;

-- Trust Center findings (the Trust Center check reads SNOWFLAKE.TRUST_CENTER.FINDINGS).
GRANT APPLICATION ROLE SNOWFLAKE.TRUST_CENTER_VIEWER TO ROLE AUDIT_ROLE;

-- Budgets (SHOW SNOWFLAKE.CORE.BUDGET INSTANCES and the budget spend).
GRANT APPLICATION ROLE SNOWFLAKE.BUDGET_VIEWER TO ROLE AUDIT_ROLE;

-- Data quality expectation results (SNOWFLAKE.LOCAL); IMPORTED PRIVILEGES does not open them.
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE AUDIT_ROLE;

-- Authentication and password policies. POLICY_REFERENCES does not list them, so the checks use
-- SHOW AUTHENTICATION POLICIES and SHOW PASSWORD POLICIES, which need a privilege on the account.
GRANT APPLY AUTHENTICATION POLICY ON ACCOUNT TO ROLE AUDIT_ROLE;
GRANT APPLY PASSWORD POLICY ON ACCOUNT TO ROLE AUDIT_ROLE;

-- Optional: the organization billing views (invoice, rates, contract balance).
-- In an ORGADMIN-enabled account they are database roles of the SNOWFLAKE database:
GRANT DATABASE ROLE SNOWFLAKE.ORGANIZATION_BILLING_VIEWER TO ROLE AUDIT_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.ORGANIZATION_USAGE_VIEWER TO ROLE AUDIT_ROLE;
-- In the organization account they are application roles instead (run as GLOBALORGADMIN):
--   GRANT APPLICATION ROLE SNOWFLAKE.ORGANIZATION_BILLING_VIEWER TO ROLE AUDIT_ROLE;

-- The user the export signs in as, with its public key.
CREATE USER IF NOT EXISTS AUDIT_USER DEFAULT_ROLE = AUDIT_ROLE DEFAULT_WAREHOUSE = AUDIT_WH
  TYPE = SERVICE RSA_PUBLIC_KEY = '<public key, without the BEGIN/END lines>';
GRANT ROLE AUDIT_ROLE TO USER AUDIT_USER;
