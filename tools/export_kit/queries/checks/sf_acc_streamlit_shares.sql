-- query_id: sf_acc_streamlit_shares
-- title: Who each Streamlit app was shared with, by whom and when
-- domain: governance_access   tier: standard
-- entity: apps = app_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one grant on a Streamlit app, which is how an app is shared: GRANT USAGE ON
--   STREAMLIT app TO ROLE role. granted_at is when it was granted, revoked_at when it was revoked (NULL while it stands),
--   granted_by the role that granted it. Live grants say who can open the app today; the page walks the
--   role hierarchy from them to the users.
-- healthy: status = OK when the app is shared with named roles; this check lists, it does not judge beyond
--   PUBLIC.
-- investigate_if: WARN when the app is shared with PUBLIC (every user can open it).
-- actions: 1) share the app with the roles of the people who need it, not PUBLIC (free)
-- next: sf_use_streamlit_access
-- empty_if: role_cannot_see, no_activity
-- caveats: GRANTS_TO_ROLES lists grants on live apps only; an app dropped and its grants are gone. Lags up to
--   2 hours. Grants to database roles show the database role.
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       UPPER(table_catalog || '.' || table_schema || '.' || name) AS app_name, UPPER(privilege) AS privilege,
       UPPER(grantee_name) AS grantee_name, UPPER(granted_to) AS granted_to, UPPER(NULLIF(granted_by, '')) AS granted_by,
       created_on::TIMESTAMP_NTZ AS granted_at, deleted_on::TIMESTAMP_NTZ AS revoked_at,
       IFF(deleted_on IS NULL AND UPPER(grantee_name) = 'PUBLIC', 'WARN', 'OK') AS status
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE UPPER(granted_on) = 'STREAMLIT'
ORDER BY app_name, granted_at DESC
