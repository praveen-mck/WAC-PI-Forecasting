l-- =====================================================================
-- SECTION 1: OVERALL ERROR DISTRIBUTION
-- =====================================================================
SELECT
    'ALL'                                               AS price_decrease_filter,
    run_id,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(error_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS weighted_bias_dollars
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id

UNION ALL

SELECT
    'NO_WAC_PRICE_DECREASE_FLAG'                        AS price_decrease_filter,
    run_id,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(error_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS weighted_bias_dollars
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
  AND wac_price_decrease_flag = 0
GROUP BY run_id

ORDER BY run_id, price_decrease_filter
;


-- =====================================================================
-- SECTION 1A: ERROR BY CUST_SEGMENT
-- =====================================================================
SELECT
    'ALL'                                               AS price_decrease_filter,
    run_id,
    cust_segment,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, cust_segment

UNION ALL

SELECT
    'NO_WAC_PRICE_DECREASE_FLAG'                        AS price_decrease_filter,
    run_id,
    cust_segment,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
  AND wac_price_decrease_flag = 0
GROUP BY run_id, cust_segment

ORDER BY run_id, cust_segment, price_decrease_filter
;


-- =====================================================================
-- SECTION 1B: ERROR BY ACCT_CLASSIFICATION
-- =====================================================================
SELECT
    'ALL'                                               AS price_decrease_filter,
    run_id,
    acct_classification,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, acct_classification

UNION ALL

SELECT
    'NO_WAC_PRICE_DECREASE_FLAG'                        AS price_decrease_filter,
    run_id,
    acct_classification,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
  AND wac_price_decrease_flag = 0
GROUP BY run_id, acct_classification

ORDER BY run_id, acct_classification, price_decrease_filter
;


-- =====================================================================
-- SECTION 1C: ERROR BY CUST_PROD_CATEGORY
-- =====================================================================
SELECT
    'ALL'                                               AS price_decrease_filter,
    run_id,
    cust_prod_category,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, cust_prod_category

UNION ALL

SELECT
    'NO_WAC_PRICE_DECREASE_FLAG'                        AS price_decrease_filter,
    run_id,
    cust_prod_category,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
  AND wac_price_decrease_flag = 0
GROUP BY run_id, cust_prod_category

ORDER BY run_id, cust_prod_category, price_decrease_filter
;


-- =====================================================================
-- SECTION 1D: ERROR BY CUST_SEGMENT x ACCT_CLASSIFICATION
-- =====================================================================
SELECT
    'ALL'                                               AS price_decrease_filter,
    run_id,
    cust_segment,
    acct_classification,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, cust_segment, acct_classification

UNION ALL

SELECT
    'NO_WAC_PRICE_DECREASE_FLAG'                        AS price_decrease_filter,
    run_id,
    cust_segment,
    acct_classification,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
  AND wac_price_decrease_flag = 0
GROUP BY run_id, cust_segment, acct_classification

ORDER BY run_id, cust_segment, acct_classification, price_decrease_filter
;


-- =====================================================================
-- SECTION 1E: ERROR BY CUST_SEGMENT x ACCT_CLASSIFICATION x CUST_PROD_CATEGORY
-- =====================================================================
SELECT
    'ALL'                                               AS price_decrease_filter,
    run_id,
    cust_segment,
    acct_classification,
    cust_prod_category,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
GROUP BY run_id, cust_segment, acct_classification, cust_prod_category

UNION ALL

SELECT
    'NO_WAC_PRICE_DECREASE_FLAG'                        AS price_decrease_filter,
    run_id,
    cust_segment,
    acct_classification,
    cust_prod_category,
    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,
    ROUND(SUM(ABS(actual_dollars)), 2)                  AS total_actual_dollars,
    ROUND(SUM(ABS(forecasted_dollars)), 2)              AS total_forecasted_dollars,
    ROUND(SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)), 2)
                                                        AS variance_dollars,
    ROUND((SUM(ABS(forecasted_dollars)) - SUM(ABS(actual_dollars)))
        / NULLIF(SUM(ABS(actual_dollars)), 0), 4)       AS variance_pct,
    ROUND(AVG(ape_dollars), 4)                          AS mape_dollars,
    ROUND(SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0), 4)
                                                        AS wmape_dollars,
    ROUND(AVG(bias_dollars), 4)                         AS avg_bias_dollars,
    ROUND(SUM(ABS(actual_dollars)) / NULLIF(
        SUM(SUM(ABS(actual_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_revenue,
    ROUND(SUM(ABS(error_dollars)) / NULLIF(
        SUM(SUM(ABS(error_dollars))) OVER (PARTITION BY run_id), 0), 4)
                                                        AS pct_of_total_error
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v20
WHERE forecast_month IS NOT NULL
  AND actual_contract_price IS NOT NULL
  AND wac_price_decrease_flag = 0
GROUP BY run_id, cust_segment, acct_classification, cust_prod_category

ORDER BY run_id, cust_segment, acct_classification, cust_prod_category, price_decrease_filter
;