/* =====================================================================
   BACKTEST ERROR DIAGNOSTICS (v16)
   ---------------------------------------------------------------------
   PURPOSE
   - Identify the largest sources of forecast error in the v16 pipeline
   - Each section answers a specific diagnostic question
   - Run sections independently or together
   - All sections source from contract_price_bt_eval_detail_v16

   SECTION INDEX
   1.  Overall error distribution — is error concentrated or spread?
   2.  Error by MODEL_TIER — does granularity tier drive error?
   3.  Error by sparse_price_confidence — does thin history drive error?
   4.  Error by forecast_start_price_source — which price rule fails most?
   5.  Error by forecast horizon — does error grow over time?
   6.  Error by cust_segment + acct_classification — which trade class?
   7.  Error by cust_prod_category — generic vs branded vs OTC?
   8.  Error by materiality band — where is dollar impact concentrated?
   9.  Error by months_since_first_asof_jumpoff — new vs mature series?
   10. Top error series — which specific keys drive the most dollar error?
   11. Bias decomposition — are we systematically high or low by cohort?
   12. Forecast explosion audit — which series exploded and why?
   13. Price source transition — does anchor vs avg choice matter?
   14. WAC spread vs price error — is spread volatility a predictor of error?
   ===================================================================== */

-- =====================================================================
-- SECTION 1: OVERALL ERROR DISTRIBUTION
-- Answers: Is error concentrated in a few outliers or broadly spread?
-- Look for: p90/p95 much larger than median -> outlier-driven
-- =====================================================================
-- =====================================================================
-- SECTION 1: OVERALL ERROR DISTRIBUTION
-- Answers: Is error concentrated in a few outliers or broadly spread?
-- Look for: p90/p95 much larger than median -> outlier-driven
-- =====================================================================
SELECT
    run_id,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,

    -- price error distribution
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(MEDIAN(ape_contract_price), 4)                AS median_ape_price,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY ape_contract_price), 4)
                                                        AS p75_ape_price,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY ape_contract_price), 4)
                                                        AS p90_ape_price,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY ape_contract_price), 4)
                                                        AS p95_ape_price,

    -- dollar error distribution
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(MEDIAN(ape_dollars), 4)                       AS median_ape_dollars,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY ape_dollars), 4)
                                                        AS p75_ape_dollars,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY ape_dollars), 4)
                                                        AS p90_ape_dollars,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY ape_dollars), 4)
                                                        AS p95_ape_dollars,

    -- weighted metrics
    -- WAPE: weights by forecasted dollars (forecast-denominated)
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,

    -- WMAPE: weights by actual dollars (actual-denominated) — identical formula
    -- here since ae_dollars = |forecast - actual| and we denominate by actual;
    -- kept as a named alias for reporting clarity
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,

    -- Bias metrics
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    -- Weighted bias: signed error / sum of actuals — directional signal at portfolio level
    ROUND(SUM(error_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS weighted_bias_dollars,

    -- error concentration: what share of total dollar error comes from top 10% of rows?
    ROUND(
        SUM(CASE WHEN ape_dollars >= p90_ape_dollars_threshold
                 THEN ABS(error_dollars) ELSE 0 END)
        / NULLIF(SUM(ABS(error_dollars)), 0)
    , 4)                                                AS pct_error_from_top10pct_rows

FROM (
    SELECT *,
        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY ape_dollars)
            OVER (PARTITION BY run_id)                   AS p90_ape_dollars_threshold
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
    WHERE forecast_month IS NOT NULL
      AND actual_contract_price IS NOT NULL
) sub
GROUP BY run_id
ORDER BY run_id
;

-- =====================================================================
-- SECTION 2: ERROR BY MODEL TIER
-- Answers: Does SAP_CUST granularity perform better than L2 or fallback?
-- Look for: NATIONAL_GRP_FALLBACK with much higher MAPE than SAP_CUST
-- =====================================================================
SELECT
    run_id,
    MODEL_TIER,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(MEDIAN(ape_contract_price), 4)                AS median_ape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, MODEL_TIER
ORDER BY run_id, MODEL_TIER
;


-- =====================================================================
-- SECTION 3: ERROR BY SPARSE PRICE CONFIDENCE
-- Answers: Does thin history (< 6 months) drive disproportionate error?
-- Look for: PRICE_LAST_OBSERVED with much higher error than PRICE_6MO_AVG
-- =====================================================================
SELECT
    run_id,
    sparse_price_confidence,
    is_sparse_price_flag,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(MEDIAN(ape_contract_price), 4)                AS median_ape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, sparse_price_confidence, is_sparse_price_flag
ORDER BY run_id, is_sparse_price_flag DESC, sparse_price_confidence
;


-- =====================================================================
-- SECTION 4: ERROR BY FORECAST START PRICE SOURCE
-- Answers: Which price rule (prior avg, observed avg, last price) fails?
-- Look for: AVG_PRIOR_12M vs AVG_LATEST_12 error difference
-- =====================================================================
SELECT
    run_id,
    forecast_start_price_source,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(MEDIAN(ape_contract_price), 4)                AS median_ape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, forecast_start_price_source
ORDER BY run_id, pct_of_total_error DESC
;


-- =====================================================================
-- SECTION 5: ERROR BY FORECAST HORIZON
-- Answers: Does error grow as we forecast further out?
--          Flat error = price is stable; growing error = trend needed
-- Look for: steep climb after month 6 -> trend model may help
-- =====================================================================
SELECT
    run_id,
    forecast_horizon_month_num,
    COUNT(*)                                            AS row_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    -- positive bias = consistently forecasting too high
    ROUND(AVG(bias_contract_price), 4)                  AS avg_bias_price
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, forecast_horizon_month_num
ORDER BY run_id, forecast_horizon_month_num
;


-- =====================================================================
-- SECTION 6: ERROR BY CUST_SEGMENT + ACCT_CLASSIFICATION
-- Answers: Which customer trade class has the worst forecast accuracy?
-- Look for: segments with high WAPE and high revenue share
-- =====================================================================
SELECT
    run_id,
    cust_segment,
    acct_classification,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, cust_segment, acct_classification
ORDER BY run_id, pct_of_total_error DESC
;


-- =====================================================================
-- SECTION 7: ERROR BY CUST_PROD_CATEGORY
-- Answers: Is error concentrated in generics (GX), branded (BX), or OTC?
-- =====================================================================
SELECT
    run_id,
    cust_prod_category,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(MEDIAN(ape_contract_price), 4)                AS median_ape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, cust_prod_category
ORDER BY run_id, pct_of_total_error DESC
;


-- =====================================================================
-- SECTION 8: ERROR BY MATERIALITY BAND
-- Answers: Are we passing/failing on high-revenue series?
--          This is the threshold that matters most operationally.
-- Look for: TOP_20 with low pass_rate_materiality -> critical problem
-- =====================================================================
-- SELECT
--     run_id,
--     materiality_band,
--     materiality_threshold_pct,
--     COUNT(*)                                            AS row_cnt,
--     COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
--                                                         AS series_cnt,
--     ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
--     ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
--     ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
--                                                         AS wape_dollars,
--     ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
--     ROUND(SUM(ABS(actual_dollars)) / NULLIF(
--         SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
--                                                         AS pct_of_total_revenue,
--     -- pass rate vs materiality threshold
--     ROUND(AVG(pass_flag_vs_materiality_threshold), 4)   AS pass_rate_materiality,
--     COUNT_IF(review_priority = 'CRITICAL')              AS critical_cnt,
--     COUNT_IF(review_priority = 'MODERATE')              AS moderate_cnt,
--     COUNT_IF(review_priority = 'PASS')                  AS pass_cnt
-- FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
-- WHERE forecast_month IS NOT NULL
--   AND actual_contract_price IS NOT NULL
-- GROUP BY run_id, materiality_band, materiality_threshold_pct
-- ORDER BY run_id,
--     CASE materiality_band
--         WHEN 'TOP_20'    THEN 1
--         WHEN 'MIDDLE_60' THEN 2
--         WHEN 'BOTTOM_20' THEN 3
--         ELSE 4
--     END
-- ;


-- =====================================================================
-- SECTION 9: ERROR BY SERIES MATURITY AT JUMP-OFF
-- Answers: Are newer series (< 12 months old at jump-off) harder to forecast?
-- Bucket series age at jump-off into cohorts and compare error.
-- =====================================================================
SELECT
    run_id,
    CASE
        WHEN months_since_first_asof_jumpoff <  6  THEN '00_TO_05_MONTHS'
        WHEN months_since_first_asof_jumpoff < 12  THEN '06_TO_11_MONTHS'
        WHEN months_since_first_asof_jumpoff < 24  THEN '12_TO_23_MONTHS'
        WHEN months_since_first_asof_jumpoff < 36  THEN '24_TO_35_MONTHS'
        ELSE                                             '36_PLUS_MONTHS'
    END                                                 AS series_age_at_jumpoff,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, series_age_at_jumpoff
ORDER BY run_id, series_age_at_jumpoff
;


-- =====================================================================
-- SECTION 10: TOP ERROR SERIES
-- Answers: Which specific HYBRID_MODEL_KEY_3T + material combinations
--          drive the most total dollar error across all forecast months?
-- Use this to inspect individual series and understand root cause.
-- =====================================================================
SELECT
    run_id,
    HYBRID_MODEL_KEY_3T,
    mtrl_num,
    mtrl_nme_nvgton,
    MODEL_TIER,
    sparse_price_confidence,
    forecast_start_price_source,
    cust_segment,
    acct_classification,
    cust_prod_category,
    national_grp_desc,
    final_product_group,

    COUNT(*)                                            AS forecast_months,
    ROUND(MIN(actual_contract_price), 4)                AS min_actual_price,
    ROUND(MAX(actual_contract_price), 4)                AS max_actual_price,
    ROUND(MIN(forecasted_contract_price), 4)            AS min_forecast_price,
    ROUND(MAX(forecasted_contract_price), 4)            AS max_forecast_price,
    ROUND(AVG(anchor_contract_price), 4)                AS anchor_price,
    ROUND(AVG(forecast_start_contract_price), 4)        AS forecast_start_price,

    ROUND(SUM(ABS(error_dollars)), 2)                   AS total_abs_error_dollars,
    ROUND(SUM(actual_dollars), 2)                       AS total_actual_dollars,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,

    -- is error consistent direction (systematic) or mixed (random)?
    ROUND(
        SUM(error_dollars) / NULLIF(SUM(ABS(error_dollars)), 0)
    , 4)                                                AS directional_consistency,
    -- +1 = always over, -1 = always under, 0 = mixed

    MAX(forecast_explosion_flag)                        AS any_explosion,
    MAX(review_priority)                                AS worst_review_priority

FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY
    run_id,
    HYBRID_MODEL_KEY_3T,
    mtrl_num,
    mtrl_nme_nvgton,
    MODEL_TIER,
    sparse_price_confidence,
    forecast_start_price_source,
    cust_segment,
    acct_classification,
    cust_prod_category,
    national_grp_desc,
    final_product_group
ORDER BY total_abs_error_dollars DESC
LIMIT 100
;


-- =====================================================================
-- SECTION 11: BIAS DECOMPOSITION
-- Answers: Are we systematically over- or under-forecasting in
--          specific cohorts? Bias = directional problem that a
--          recalibration or trend signal could fix.
-- Look for: large negative bias = consistently forecasting too low
--           (prices rising faster than 0-trend assumes)
-- =====================================================================
SELECT
    run_id,
    MODEL_TIER,
    cust_segment,
    cust_prod_category,
    forecast_start_price_source,

    COUNT(*)                                            AS row_cnt,
    ROUND(AVG(bias_contract_price), 4)                  AS avg_bias_price,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(MEDIAN(bias_contract_price), 4)               AS median_bias_price,

    -- pct of rows with positive bias (over-forecast)
    ROUND(AVG(CASE WHEN bias_contract_price > 0 THEN 1.0 ELSE 0.0 END), 4)
                                                        AS pct_over_forecast,
    -- pct of rows with negative bias (under-forecast)
    ROUND(AVG(CASE WHEN bias_contract_price < 0 THEN 1.0 ELSE 0.0 END), 4)
                                                        AS pct_under_forecast,

    -- net dollar bias: positive = we're booking too much, negative = too little
    ROUND(SUM(error_dollars), 2)                        AS net_error_dollars

FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY
    run_id,
    MODEL_TIER,
    cust_segment,
    cust_prod_category,
    forecast_start_price_source
HAVING COUNT(*) >= 30   -- only report cohorts with enough rows to be meaningful
ORDER BY ABS(AVG(bias_dollars)) DESC
;


-- =====================================================================
-- SECTION 12: FORECAST EXPLOSION AUDIT
-- Answers: Which series exploded (forecast > 3x anchor)?
--          Is it a data quality issue or a model issue?
-- =====================================================================
SELECT
    run_id,
    HYBRID_MODEL_KEY_3T,
    mtrl_num,
    mtrl_nme_nvgton,
    MODEL_TIER,
    cust_segment,
    acct_classification,
    cust_prod_category,
    forecast_start_price_source,
    sparse_price_confidence,

    ROUND(AVG(anchor_contract_price), 4)                AS anchor_price,
    ROUND(AVG(forecast_start_contract_price), 4)        AS forecast_start_price,
    ROUND(MAX(forecasted_contract_price), 4)            AS max_forecasted_price,
    ROUND(AVG(actual_contract_price), 4)                AS avg_actual_price,

    COUNT(*)                                            AS explosion_months,
    ROUND(SUM(ABS(error_dollars)), 2)                   AS total_abs_error_dollars,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price

FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_explosion_flag = 1
  AND forecast_month IS NOT NULL
GROUP BY
    run_id,
    HYBRID_MODEL_KEY_3T,
    mtrl_num,
    mtrl_nme_nvgton,
    MODEL_TIER,
    cust_segment,
    acct_classification,
    cust_prod_category,
    forecast_start_price_source,
    sparse_price_confidence
ORDER BY total_abs_error_dollars DESC
;


-- =====================================================================
-- SECTION 13: PRICE SOURCE TRANSITION ANALYSIS
-- Answers: When anchor_contract_price != forecast_start_contract_price
--          (i.e. the avg rule kicked in), did it help or hurt?
-- Compares error when avg rule was used vs when anchor was used directly.
-- =====================================================================
SELECT
    run_id,
    CASE
        WHEN ABS(anchor_contract_price - forecast_start_contract_price)
             < 0.001 * NULLIF(anchor_contract_price, 0)
        THEN 'ANCHOR_USED_DIRECTLY'
        ELSE 'AVG_RULE_APPLIED'
    END                                                 AS price_start_method,
    forecast_start_price_source,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
  AND anchor_contract_price IS NOT NULL
  AND forecast_start_contract_price IS NOT NULL
GROUP BY run_id, price_start_method, forecast_start_price_source
ORDER BY run_id, price_start_method, forecast_start_price_source
;


-- =====================================================================
-- SECTION 14: WAC SPREAD VOLATILITY VS PRICE ERROR
-- Answers: Do series with high WAC spread volatility have higher error?
--          If yes, spread stability is a useful feature or filter.
-- Buckets series by the difference between anchor and actual spread.
-- =====================================================================
SELECT
    run_id,
    CASE
        WHEN ABS(actual_wac_spread - anchor_wac_spread) < 0.05   THEN 'SPREAD_STABLE_LT5PCT'
        WHEN ABS(actual_wac_spread - anchor_wac_spread) < 0.15   THEN 'SPREAD_SHIFT_5_TO_15PCT'
        WHEN ABS(actual_wac_spread - anchor_wac_spread) < 0.30   THEN 'SPREAD_SHIFT_15_TO_30PCT'
        ELSE                                                           'SPREAD_SHIFT_GT30PCT'
    END                                                 AS spread_shift_bucket,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(AVG(ape_contract_price), 4)                   AS mape_price,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v16
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
  AND actual_wac_spread IS NOT NULL
  AND anchor_wac_spread IS NOT NULL
GROUP BY run_id, spread_shift_bucket
ORDER BY run_id,
    CASE spread_shift_bucket
        WHEN 'SPREAD_STABLE_LT5PCT'      THEN 1
        WHEN 'SPREAD_SHIFT_5_TO_15PCT'   THEN 2
        WHEN 'SPREAD_SHIFT_15_TO_30PCT'  THEN 3
        ELSE 4
    END
;