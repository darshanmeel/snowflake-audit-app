-- query_id: sf_cost_contract_balance_burn
-- title: Contract balance runway at the current burn rate
-- domain: cost   tier: standard
-- money: prepaid_balance
-- entity: contracts = contract_number
-- windowed: no
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.REMAINING_BALANCE_DAILY,
--   SNOWFLAKE.ORGANIZATION_USAGE.CONTRACT_ITEMS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :burn_days (default 30) burn days: value this check uses; :warn_runway_days (default 90)
--   runway days: at or above this the row reads WARN; :crit_runway_days (default 30) runway days: at or
--   above this the row reads CRITICAL; :warn_unused_pct (default 20) unused pct: at or above this the
--   row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one contract. prepaid_balance = capacity + rollover + free usage balance on the
--   latest day; daily_burn = average daily drawdown over the last burn_days (top-ups ignored);
--   runway_days = how long the balance lasts at that rate. projected_unused = balance left at the
--   contract end date at this rate (negative = on-demand overage before renewal).
-- healthy: status = OK when the balance lasts until the contract ends and little is left unused.
-- investigate_if: WARN when runway is under warn_runway_days, runs out before the contract end, or >=
--   warn_unused_pct of today's balance would be left unused; CRITICAL when runway is under
--   crit_runway_days, or when the prepaid balance is already used up inside the contract term
--   (is_exhausted: usage now bills as on-demand overage).
-- actions: 1) share the runway and end date with finance and the account owner (free); 2) when short:
--   cut the top items in sf_cost_serverless_features and idle warehouses; when long: pull planned work
--   forward or negotiate rollover (config); 3) amend the contract capacity before overage bills at
--   on-demand rates (spend).
-- next: none
-- caveats: needs ORGANIZATION_USAGE access (ORGADMIN or a granted role); without it this check fails.
--   The balance is for the whole organization, not this account. Amounts are in the contract currency,
--   not list USD. A straight-line burn misses seasonality and planned growth.
WITH bal AS (
  SELECT contract_number, "DATE" AS balance_date, currency,
         COALESCE(capacity_balance, 0) + COALESCE(rollover_balance, 0)
           + COALESCE(free_usage_balance, 0) AS prepaid_balance,
         on_demand_consumption_balance AS on_demand_balance
  FROM SNOWFLAKE.ORGANIZATION_USAGE.REMAINING_BALANCE_DAILY
  WHERE "DATE" >= DATEADD(day, -(:burn_days + 1), __AS_OF_DATE__) AND "DATE" < __AS_OF_DATE__
),
d AS (
  SELECT bal.*,
         LAG(prepaid_balance) OVER (PARTITION BY contract_number ORDER BY balance_date)
           - prepaid_balance AS drawdown
  FROM bal
),
agg AS (
  SELECT contract_number, MAX(currency) AS currency, MAX(balance_date) AS latest_date,
         MAX_BY(prepaid_balance, balance_date) AS prepaid_balance,
         MAX_BY(on_demand_balance, balance_date) AS on_demand_balance,
         SUM(IFF(drawdown > 0, drawdown, 0)) / NULLIF(COUNT(drawdown), 0) AS daily_burn,
         SUM(IFF(drawdown < 0, -drawdown, 0)) AS top_ups
  FROM d
  GROUP BY contract_number
),
ct AS (
  SELECT contract_number, MAX(end_date) AS contract_end_date
  FROM SNOWFLAKE.ORGANIZATION_USAGE.CONTRACT_ITEMS
  GROUP BY contract_number
),
s AS (
  SELECT agg.*, ct.contract_end_date,
         IFF(prepaid_balance > 0, prepaid_balance / NULLIF(daily_burn, 0), NULL) AS runway_days,
         DATEDIFF(day, __AS_OF_DATE__, ct.contract_end_date) AS days_to_contract_end,
         prepaid_balance - daily_burn * DATEDIFF(day, __AS_OF_DATE__, ct.contract_end_date) AS projected_unused
  FROM agg LEFT JOIN ct ON ct.contract_number = agg.contract_number
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, TO_VARCHAR(contract_number) AS contract_number,
       currency, latest_date, prepaid_balance, on_demand_balance, daily_burn, top_ups,
       runway_days, DATEADD(day, FLOOR(runway_days), latest_date) AS projected_depletion_date,
       contract_end_date, days_to_contract_end, projected_unused,
       100 * projected_unused / NULLIF(prepaid_balance, 0) AS projected_unused_pct,
       COALESCE(prepaid_balance, 0) <= 0 AND COALESCE(contract_end_date, __AS_OF_DATE__) >= __AS_OF_DATE__ AS is_exhausted,
       CASE WHEN COALESCE(daily_burn, 0) = 0 AND NOT (COALESCE(prepaid_balance, 0) <= 0
                 AND COALESCE(contract_end_date, __AS_OF_DATE__) >= __AS_OF_DATE__) THEN 'no_drawdown_seen' END AS not_assessed_reason,
       CASE
         -- Prepaid capacity is used up inside the contract term: usage now bills as on-demand overage.
         WHEN COALESCE(prepaid_balance, 0) <= 0 AND COALESCE(contract_end_date, __AS_OF_DATE__) >= __AS_OF_DATE__ THEN 'CRITICAL'
         WHEN COALESCE(daily_burn, 0) = 0 THEN 'NOT_ASSESSED'
         WHEN runway_days < :crit_runway_days THEN 'CRITICAL'
         WHEN runway_days < :warn_runway_days THEN 'WARN'
         WHEN days_to_contract_end > 0 AND runway_days < days_to_contract_end THEN 'WARN'
         WHEN days_to_contract_end > 0 AND 100 * projected_unused / NULLIF(prepaid_balance, 0) >= :warn_unused_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY is_exhausted DESC, runway_days NULLS LAST
