-- query_id: sf_ai_cortex_code_spend
-- title: Cortex Code (CLI, Snowsight and Desktop) spend per user, checked against the billed total
-- domain: serving_ai   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 1) settle days: last days left out on both sides of the billed total;
--   :min_spend_usd (default 25) spend usd: least a user row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :warn_share_pct (default 50) share pct: at or above this the row reads WARN;
--   :warn_gap_pct (default 10) gap pct: usage credits this far from the billed total read WARN
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user of one Cortex Code surface (CLI, Snowsight or Desktop), plus a billed-total row per
--   surface. gap_credits = usage credits minus billed credits; it is a check on the data, not spend.
--   current = the window, previous = the window before.
-- healthy: status = OK when a user's spend is small or flat and the usage credits match the billed total.
-- investigate_if: WARN when a user spending >= min_spend_usd is new, grew >= warn_increase_pct, or makes
--   >= warn_share_pct of a surface; CRITICAL when it grew >= crit_increase_pct; the total row reads WARN
--   when the gap is >= warn_gap_pct of the billed credits.
-- actions: 1) ask the top users what they run in Cortex Code and whether it is worth it (free); 2) move
--   heavy users to a smaller model, or restrict the feature to the teams that use it (config); 3) set an
--   AI budget for Cortex Code before it grows further (spend).
-- next: sf_ai_spend_by_feature_reconciled
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced
-- caveats: usage times are converted to UTC days to line up with the daily metering view, and the last
--   settle_days are left out of both sides so the gap is not an artefact of the cut-off. Cortex Code is
--   its own service type, not part of AI_SERVICES; Snowsight bills as CORTEX_CODE_SNOWSIGHT or
--   SNOWFLAKE_COCO_SNOWSIGHT. The total row carries no dollar figure, so dollars are
--   never counted twice. Users and totals are per surface and never added across surfaces to the bill.
--   Desktop has no documented service type in METERING_DAILY_HISTORY: its total row ties out only if the
--   bill carries CORTEX_CODE_DESKTOP, and a missing billed figure is not flagged.
WITH u AS (
  SELECT 'CLI' AS surface, user_id, user_name, token_credits, tokens,
         CAST(CONVERT_TIMEZONE('UTC', usage_time) AS DATE) AS usage_day
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY
  UNION ALL
  SELECT 'SNOWSIGHT', user_id, user_name, token_credits, tokens,
         CAST(CONVERT_TIMEZONE('UTC', usage_time) AS DATE)
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY
  UNION ALL
  SELECT 'DESKTOP', user_id, user_name, token_credits, tokens,
         CAST(CONVERT_TIMEZONE('UTC', usage_time) AS DATE)
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY
),
w AS (
  SELECT surface,
         COALESCE(user_name || ' (' || TO_VARCHAR(user_id) || ')', 'unknown (' || COALESCE(TO_VARCHAR(user_id), '?') || ')') AS user_name,
         SUM(IFF(usage_day >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), token_credits, 0)) AS cur_credits,
         SUM(IFF(usage_day < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), token_credits, 0)) AS prev_credits,
         SUM(IFF(usage_day >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), tokens, 0)) AS cur_tokens
  FROM u
  WHERE usage_day >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_day < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY 1, 2
),
-- live accounts bill Snowsight as SNOWFLAKE_COCO_SNOWSIGHT, the docs say CORTEX_CODE_SNOWSIGHT: the larger per day so a day under both is not counted twice
billed_day AS (
  SELECT CASE WHEN service_type = 'CORTEX_CODE_CLI' THEN 'CLI'
              WHEN service_type IN ('CORTEX_CODE_SNOWSIGHT', 'SNOWFLAKE_COCO_SNOWSIGHT') THEN 'SNOWSIGHT'
              ELSE 'DESKTOP' END AS surface,
         usage_date, service_type, SUM(credits_billed) AS credits_billed
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE service_type IN ('CORTEX_CODE_CLI', 'CORTEX_CODE_SNOWSIGHT', 'SNOWFLAKE_COCO_SNOWSIGHT', 'CORTEX_CODE_DESKTOP')
    AND usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__)
    AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY usage_date, service_type
),
billed AS (
  SELECT surface, SUM(credits_billed) AS billed_credits
  FROM (SELECT surface, usage_date, MAX(credits_billed) AS credits_billed FROM billed_day GROUP BY surface, usage_date)
  GROUP BY surface
),
users AS (
  SELECT w.*, 'user' AS row_kind,
         100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * cur_credits / NULLIF(SUM(cur_credits) OVER (PARTITION BY surface), 0) AS share_pct,
         CAST(NULL AS DOUBLE) AS billed_credits, CAST(NULL AS DOUBLE) AS gap_credits
  FROM w
),
totals AS (
  SELECT COALESCE(w.surface, b.surface) AS surface, '(all users, billed total)' AS user_name,
         COALESCE(SUM(w.cur_credits), 0) AS cur_credits, CAST(NULL AS DOUBLE) AS prev_credits,
         COALESCE(SUM(w.cur_tokens), 0) AS cur_tokens, 'total' AS row_kind,
         CAST(NULL AS DOUBLE) AS change_pct, CAST(NULL AS DOUBLE) AS share_pct,
         MAX(b.billed_credits) AS billed_credits,
         COALESCE(SUM(w.cur_credits), 0) - COALESCE(MAX(b.billed_credits), 0) AS gap_credits
  FROM w FULL OUTER JOIN billed b ON b.surface = w.surface
  GROUP BY COALESCE(w.surface, b.surface)
),
r AS (
  SELECT * FROM users
  UNION ALL
  SELECT * FROM totals
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, surface, row_kind, row_kind = 'total' AS is_total_row, user_name,
       cur_tokens AS current_tokens, cur_credits AS current_credits, prev_credits AS previous_credits,
       change_pct, share_pct AS share_of_surface_pct, billed_credits, gap_credits,
       IFF(row_kind = 'user', cur_credits * __AI_CREDIT_PRICE__, NULL) AS est_current_usd_list,
       IFF(row_kind = 'user', prev_credits * __AI_CREDIT_PRICE__, NULL) AS est_previous_usd_list,
       IFF(row_kind = 'user' AND __AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN row_kind = 'user' AND __AI_CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN row_kind = 'total' THEN
           CASE WHEN 100 * ABS(gap_credits) / NULLIF(billed_credits, 0) >= :warn_gap_pct
                     OR (billed_credits IS NULL AND cur_credits > 0 AND surface <> 'DESKTOP') THEN 'WARN' ELSE 'OK' END
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_credits * __AI_CREDIT_PRICE__ < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct OR share_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM r
ORDER BY surface, row_kind DESC, current_credits DESC
