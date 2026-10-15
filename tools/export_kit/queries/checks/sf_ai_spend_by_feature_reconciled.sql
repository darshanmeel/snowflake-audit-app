-- query_id: sf_ai_spend_by_feature_reconciled
-- title: AI spend by Cortex feature, reconciled to the billed AI total (provisioned throughput on
--   its own line)
-- domain: serving_ai   tier: standard
-- entity: AI features = feature
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FINE_TUNING_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :settle_days (default 2) settle days: last days left out on both sides of the billed total;
--   :min_spend_usd (default 25) spend usd: least a row needs before it can flag;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL;
--   :warn_gap_pct (default 10) gap pct: unexplained credits at or above this share of the billed total
--   read WARN; :crit_gap_pct (default 30) gap pct: at or above this the total row reads CRITICAL
-- empty_if: view_missing, role_cannot_see, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Document-processing and fine-tuning columns are from the
--   view catalog and not yet checked against a live account.
-- read_this: One row = one Cortex feature with its credits and share of the billed AI total, plus a
--   total row. Provisioned throughput is a separate row outside the feature sum. On the total row,
--   feature_credits adds the features only, ptu_in_bill_credits is the provisioned throughput that fits
--   in billed minus features, and unexplained_credits = billed minus features minus that, so a large
--   gap means AI spend nothing here explains.
-- healthy: status = OK when features are small or flat and explain the billed total.
-- investigate_if: WARN when a feature spending >= min_spend_usd is new or grew >= warn_increase_pct, or
--   the total row leaves >= warn_gap_pct unexplained (or the features exceed the bill); CRITICAL when a
--   feature grew >= crit_increase_pct or the gap is >= crit_gap_pct.
-- actions: 1) open the check for the biggest or unexplained feature (sf_ai_functions_spend_by_user,
--   sf_ai_agent_spend, sf_ai_cortex_analyst_spend, sf_ai_cortex_search_spend) (free); 2) cap the feature
--   that grew: smaller models, fewer refreshes, caching (config); 3) set an AI budget line before it
--   grows further (spend).
-- next: sf_ai_functions_spend_by_user, sf_ai_agent_spend
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the spend cannot be
--   priced
-- caveats: days are UTC and the last settle_days are left out on both sides. AI_PARSE_DOCUMENT is
--   metered in the AI functions view and Document processing has its own view, so
--   document-processing function names are left out of the AI functions row to avoid counting pages
--   twice; confirm the overlap on live data. The agent row is token credits only. The billed total reads
--   AI_SERVICES or AI_INFERENCE (the name live accounts bill under). Cortex Code is a
--   separate service type and not in AI_SERVICES. Whether the billed AI_SERVICES total includes
--   provisioned throughput is not documented, so it explains the gap only up to its size and is never
--   added to the features; sf_ai_provisioned_throughput_use covers it in detail. The Cortex REST API view has tokens but
--   no credits, so it cannot be a row here or in the sum, and its spend shows only inside the
--   billed total's unexplained gap. The total row carries no dollar figure, so dollars are never
--   counted twice, and the unexplained gap is shown in credits only, never added to the features.
--   If a feature view is not readable the whole check is not assessed rather than showing a gap.
WITH f AS (
  SELECT 'AI functions' AS feature, CAST(CONVERT_TIMEZONE('UTC', start_time) AS DATE) AS usage_day, credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
  WHERE function_name NOT ILIKE '%PARSE_DOCUMENT%'
  UNION ALL
  SELECT 'Analyst', CAST(CONVERT_TIMEZONE('UTC', start_time) AS DATE), credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
  UNION ALL
  SELECT 'Search', CAST(usage_date AS DATE), credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
  UNION ALL
  SELECT 'Document processing', CAST(CONVERT_TIMEZONE('UTC', start_time) AS DATE), credits_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY
  UNION ALL
  SELECT 'Fine-tuning', CAST(CONVERT_TIMEZONE('UTC', start_time) AS DATE), token_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FINE_TUNING_USAGE_HISTORY
  UNION ALL
  SELECT 'Agents', CAST(CONVERT_TIMEZONE('UTC', start_time) AS DATE), token_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
  UNION ALL
  SELECT 'Provisioned throughput', CAST(CONVERT_TIMEZONE('UTC', interval_start_time) AS DATE), ptu_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY
),
feat AS (
  SELECT feature,
         SUM(IFF(usage_day >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits, 0)) AS cur_credits,
         SUM(IFF(usage_day < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits, 0)) AS prev_credits
  FROM f
  WHERE usage_day >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
    AND usage_day < DATEADD(day, -:settle_days, __AS_OF_DATE__)
  GROUP BY feature
),
-- live accounts bill AI as AI_INFERENCE, the docs say AI_SERVICES: take the larger per day so a day under both is not counted twice
ai_day AS (
  SELECT usage_date, MAX(credits_billed) AS credits_billed
  FROM (SELECT usage_date, service_type, SUM(credits_billed) AS credits_billed
        FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
        WHERE service_type IN ('AI_SERVICES', 'AI_INFERENCE')
          AND usage_date >= DATEADD(day, -(2 * :period_days + :settle_days), __AS_OF_DATE__)
          AND usage_date < DATEADD(day, -:settle_days, __AS_OF_DATE__)
        GROUP BY usage_date, service_type)
  GROUP BY usage_date
),
billed AS (
  SELECT SUM(IFF(usage_date >= DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits_billed, 0)) AS billed_credits,
         SUM(IFF(usage_date < DATEADD(day, -(:period_days + :settle_days), __AS_OF_DATE__), credits_billed, 0)) AS prev_billed_credits
  FROM ai_day
),
r AS (
  SELECT feat.feature, IFF(feat.feature = 'Provisioned throughput', 'provisioned', 'feature') AS row_kind,
         cur_credits, prev_credits,
         CAST(NULL AS DOUBLE) AS billed_credits, CAST(NULL AS DOUBLE) AS ptu_in_bill_credits,
         CAST(NULL AS DOUBLE) AS unexplained_credits
  FROM feat
  UNION ALL
  SELECT 'AI_SERVICES billed total', 'total', feature_credits, CAST(NULL AS DOUBLE), billed_credits,
         ptu_in_bill, billed_credits - feature_credits - ptu_in_bill
  FROM (
    SELECT b.billed_credits, fc.feature_credits,
           -- provisioned throughput explains the gap only as far as the gap reaches
           LEAST(GREATEST(b.billed_credits - fc.feature_credits, 0), fc.ptu_credits) AS ptu_in_bill
    FROM billed b
    CROSS JOIN (SELECT COALESCE(SUM(IFF(feature <> 'Provisioned throughput', cur_credits, 0)), 0) AS feature_credits,
                       COALESCE(SUM(IFF(feature = 'Provisioned throughput', cur_credits, 0)), 0) AS ptu_credits
                FROM feat) fc
  )
),
s AS (
  SELECT r.*, 100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         IFF(row_kind = 'provisioned', NULL,
             100 * cur_credits / NULLIF((SELECT billed_credits FROM billed), 0)) AS share_of_billed_pct,
         100 * unexplained_credits / NULLIF(billed_credits, 0) AS unexplained_pct
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, feature, row_kind, row_kind = 'total' AS is_total_row,
       cur_credits AS current_credits, prev_credits AS previous_credits, change_pct, share_of_billed_pct,
       billed_credits, ptu_in_bill_credits, unexplained_credits, unexplained_pct,
       IFF(row_kind <> 'total', cur_credits * __AI_CREDIT_PRICE__, NULL) AS est_current_usd_list,
       IFF(row_kind <> 'total', prev_credits * __AI_CREDIT_PRICE__, NULL) AS est_previous_usd_list,
       IFF(__AI_CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __AI_CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN row_kind = 'total' THEN
           CASE WHEN ABS(unexplained_pct) >= :crit_gap_pct
                     AND ABS(unexplained_credits) * __AI_CREDIT_PRICE__ >= :min_spend_usd THEN 'CRITICAL'
                WHEN ABS(unexplained_pct) >= :warn_gap_pct
                     AND ABS(unexplained_credits) * __AI_CREDIT_PRICE__ >= :min_spend_usd THEN 'WARN'
                WHEN billed_credits IS NULL AND cur_credits * __AI_CREDIT_PRICE__ >= :min_spend_usd THEN 'WARN'
                ELSE 'OK' END
         WHEN cur_credits * __AI_CREDIT_PRICE__ < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY CASE row_kind WHEN 'total' THEN 0 WHEN 'feature' THEN 1 ELSE 2 END, current_credits DESC
