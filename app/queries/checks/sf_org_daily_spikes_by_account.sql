-- query_id: sf_org_daily_spikes_by_account
-- title: Daily spend spikes per account
-- domain: cost   tier: standard
-- money: excess_amount
-- entity: accounts = account_locator
-- windowed: yes
-- reads: SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; ORGANIZATION_BILLING_VIEWER in the
--   organization account
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 3) settle days: value this check uses; :spike_ratio (default 2) spike
--   ratio: value this check uses; :crit_ratio (default 5) ratio: at or above this the row reads
--   CRITICAL; :baseline_days (default 14) baseline days: value this check uses; :min_baseline_days
--   (default 7) baseline days: least a row needs before it can flag; :min_amount (default 50) amount:
--   least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one account-day in the window whose billed amount is at least spike_ratio x the
--   median of the prior baseline_days (account = account locator). top_usage_type = the usage type
--   that added the most over its own median that day. excess_amount = amount - median. Amounts are in
--   the invoice currency.
-- healthy: status = OK when no account-day spikes (then no rows are returned).
-- investigate_if: WARN when a day is >= spike_ratio x its baseline median and >= min_amount; CRITICAL
--   when >= crit_ratio x.
-- actions: 1) open cost_daily_spikes and query_top_by_cost in that account for the day (free); 2) add a
--   resource monitor or budget alert on the account (config); 3) move the runaway job to a capped
--   warehouse or schedule (spend).
-- next: none
-- caveats: needs ORGADMIN or a role granted the ORGANIZATION_USAGE billing viewer database roles;
--   without access this check fails. Days with fewer than min_baseline_days of history are
--   NOT_ASSESSED. Month-start storage or adjustment rows can look like spikes.
WITH d AS (
  SELECT account_locator, MAX(account_name) AS account_name, usage_date, MAX(currency) AS currency,
         SUM(usage_in_currency) AS amount
  FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days + :baseline_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY account_locator, usage_date
),
b AS (
  SELECT cur.account_locator, cur.usage_date, MEDIAN(prev.amount) AS baseline_median,
         COUNT(prev.usage_date) AS baseline_days_seen
  FROM d cur
  JOIN d prev
    ON prev.account_locator = cur.account_locator
   AND prev.usage_date >= DATEADD(day, -:baseline_days, cur.usage_date)
   AND prev.usage_date < cur.usage_date
  WHERE cur.usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
  GROUP BY cur.account_locator, cur.usage_date
),
t AS (
  -- which usage type drove the jump, against that type's own recent median
  SELECT account_locator, usage_date, usage_type, amount,
         amount - MEDIAN(amount) OVER (PARTITION BY account_locator, usage_type) AS over_median
  FROM (
    SELECT account_locator, usage_date, usage_type, SUM(usage_in_currency) AS amount
    FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
    WHERE usage_date >= DATEADD(day, -(:period_days + :settle_days + :baseline_days), __AS_OF_DATE__)
      AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
    GROUP BY account_locator, usage_date, usage_type
  )
),
top_t AS (
  SELECT account_locator, usage_date, MAX_BY(usage_type, over_median) AS top_usage_type,
         MAX(over_median) AS top_usage_type_excess
  FROM t
  GROUP BY account_locator, usage_date
),
s AS (
  SELECT d.account_locator, d.account_name, d.usage_date, d.currency, d.amount,
         b.baseline_median, b.baseline_days_seen,
         d.amount / NULLIF(b.baseline_median, 0) AS spike_ratio_seen,
         d.amount - b.baseline_median AS excess_amount,
         top_t.top_usage_type, top_t.top_usage_type_excess
  FROM d
  JOIN b ON b.account_locator = d.account_locator AND b.usage_date = d.usage_date
  LEFT JOIN top_t ON top_t.account_locator = d.account_locator AND top_t.usage_date = d.usage_date
)
SELECT :period_days AS window_days, account_locator AS account_id, account_name, account_locator,
       usage_date, currency, amount, baseline_median, baseline_days_seen, spike_ratio_seen,
       excess_amount, top_usage_type, top_usage_type_excess,
       CASE WHEN baseline_days_seen < :min_baseline_days THEN 'short_baseline' END AS not_assessed_reason,
       CASE
         WHEN baseline_days_seen < :min_baseline_days THEN 'NOT_ASSESSED'
         WHEN amount < :min_amount THEN 'OK'
         WHEN amount >= :crit_ratio * baseline_median THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM s
WHERE amount >= :spike_ratio * baseline_median AND amount > 0
ORDER BY excess_amount DESC
