-- shim: NETWORK_POLICIES
-- reads: SHOW NETWORK POLICIES
-- show: SHOW NETWORK POLICIES
-- needs: MANAGE GRANTS
-- note: live network policies only; no IP lists (SHOW gives only their counts); the name stands in for the id
-- NETWORK_POLICIES rebuilt from SHOW NETWORK POLICIES: each column taken by name, mapped, or NULL where the source has none.
SELECT "name" AS id,
       CAST("name" AS VARCHAR) AS name,
       CAST(NULL AS VARCHAR) AS owner,
       CAST(NULL AS VARCHAR) AS owner_role_type,
       CAST("comment" AS VARCHAR) AS comment,
       CAST("created_on" AS TIMESTAMP_LTZ(6)) AS created,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS last_altered,
       CAST(NULL AS TIMESTAMP_LTZ(6)) AS deleted,
       CAST(NULL AS VARCHAR) AS allowed_ip_list,
       CAST(NULL AS VARCHAR) AS blocked_ip_list
FROM __SHOW__
