-- =========================================================
-- QA 1: BASE TABLE — DUPLICATE & GRAIN CHECK
-- =========================================================

SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT CONCAT_WS('|',
        customer_group_key_id,
        mtrl_num,
        cal_month_start_dt
    )) AS distinct_key_rows,

    COUNT(*) - COUNT(DISTINCT CONCAT_WS('|',
        customer_group_key_id,
        mtrl_num,
        cal_month_start_dt
    )) AS duplicate_rows
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v2;

-- =========================================================
-- QA 1B: BASE TABLE — MISSING CORE FIELDS
-- =========================================================

SELECT
    COUNT(*) AS total_rows,

    COUNT_IF(contract_price IS NULL) AS missing_contract_price,
    COUNT_IF(total_sls_qty IS NULL) AS missing_qty,
    COUNT_IF(total_net_cos IS NULL) AS missing_net_cos,
    COUNT_IF(cal_month_start_dt IS NULL) AS missing_month,
    COUNT_IF(customer_group_key_id IS NULL) AS missing_customer_key,
    COUNT_IF(mtrl_num IS NULL) AS missing_material

FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v2;

-- =========================================================
-- QA 2: TRAINING FILTER IMPACT
-- =========================================================

SELECT
    COUNT(*) AS total_rows,
    COUNT_IF(include_for_modeling_flag = 1) AS used_for_model,
    COUNT_IF(include_for_modeling_flag = 0) AS excluded_rows,

    COUNT_IF(exclude_from_training_flag = 1) AS base_flag_exclusions,
    COUNT_IF(contract_price_change_outlier_flag = 1) AS outlier_exclusions

FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v2;

-- =========================================================
-- QA 2B: EXTREME MoM CHANGES (SANITY)
-- =========================================================

SELECT
    percentile_approx(ABS(mom_contract_price_change_pct), 0.50) AS p50,
    percentile_approx(ABS(mom_contract_price_change_pct), 0.90) AS p90,
    percentile_approx(ABS(mom_contract_price_change_pct), 0.95) AS p95,
    MAX(ABS(mom_contract_price_change_pct)) AS max_change
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v2
WHERE include_for_modeling_flag = 1;

-- =========================================================
-- QA 3: HISTORY COVERAGE DISTRIBUTION
-- =========================================================

SELECT
    history_bucket,
    COUNT(*) AS series_cnt
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v2
GROUP BY history_bucket
ORDER BY series_cnt DESC;

-- =========================================================
-- QA 3B: MATERIAL WITHOUT HISTORY PROBLEM
-- =========================================================

SELECT
    COUNT(*) AS total_series,
    COUNT_IF(months_with_history = 0) AS zero_history,
    COUNT_IF(last_contract_price IS NULL) AS missing_anchor
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v2;

-- =========================================================
-- QA 4: MATERIAL TREND DISTRIBUTION
-- =========================================================

SELECT
    material_trend_source,
    COUNT(*) AS series_cnt
FROM uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v2
GROUP BY material_trend_source;

-- =========================================================
-- QA 4B: TREND RANGE SANITY
-- =========================================================

SELECT
    MIN(expected_monthly_trend_pct) AS min_trend,
    MAX(expected_monthly_trend_pct) AS max_trend,
    AVG(expected_monthly_trend_pct) AS avg_trend
FROM uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v2;

-- =========================================================
-- QA 5: FINAL TREND SOURCE DISTRIBUTION
-- =========================================================

SELECT
    trend_source,
    COUNT(*) AS series_cnt
FROM uspd_analytics_den.analytics_gold.contract_price_resolved_assumptions_v2
GROUP BY trend_source
ORDER BY series_cnt DESC;

-- =========================================================
-- QA 5B: % USING FALLBACK (CRITICAL KPI)
-- =========================================================

SELECT
    COUNT(*) AS total_series,

    COUNT_IF(trend_source = 'MATERIAL') AS material_cnt,

    COUNT_IF(trend_source <> 'MATERIAL') AS fallback_cnt,

    COUNT_IF(trend_source <> 'MATERIAL') * 1.0 / COUNT(*) AS fallback_pct
FROM uspd_analytics_den.analytics_gold.contract_price_resolved_assumptions_v2;

-- =========================================================
-- QA 6: HORIZON COVERAGE
-- =========================================================

SELECT
    MIN(forecast_horizon_month_num) AS min_horizon,
    MAX(forecast_horizon_month_num) AS max_horizon,
    COUNT(DISTINCT forecast_horizon_month_num) AS horizon_count
FROM uspd_analytics_den.analytics_gold.contract_price_future_months_v2;

-- =========================================================
-- QA 6B: ROW EXPANSION CHECK
-- =========================================================

SELECT
    COUNT(*) / COUNT(DISTINCT CONCAT_WS('|', customer_group_key_id, mtrl_num)) AS avg_rows_per_series
FROM uspd_analytics_den.analytics_gold.contract_price_future_months_v2;

-- =========================================================
-- QA 7: FINAL GRAIN CHECK (CRITICAL)
-- =========================================================

SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT CONCAT_WS('|',
        customer_group_key_id,
        mtrl_num,
        forecast_month
    )) AS distinct_rows,

    COUNT(*) - COUNT(DISTINCT CONCAT_WS('|',
        customer_group_key_id,
        mtrl_num,
        forecast_month
    )) AS duplicate_rows

FROM uspd_analytics_den.analytics_gold.contract_price_forecasted_v2;

-- =========================================================
-- QA 7B: NULL FORECAST CHECK
-- =========================================================

SELECT
    COUNT(*) AS total_rows,
    COUNT_IF(forecasted_contract_price IS NULL) AS null_forecasts
FROM uspd_analytics_den.analytics_gold.contract_price_forecasted_v2;

-- =========================================================
-- QA 8: GROWTH DISTRIBUTION
-- =========================================================

SELECT
    percentile_approx(
        forecasted_contract_price / NULLIF(anchor_contract_price, 0),
        0.50
    ) AS p50_growth,

    percentile_approx(
        forecasted_contract_price / NULLIF(anchor_contract_price, 0),
        0.90
    ) AS p90_growth,

    percentile_approx(
        forecasted_contract_price / NULLIF(anchor_contract_price, 0),
        0.95
    ) AS p95_growth,

    MAX(forecasted_contract_price / NULLIF(anchor_contract_price, 0)) AS max_growth

FROM uspd_analytics_den.analytics_gold.contract_price_forecasted_v2
WHERE forecast_horizon_month_num = 60;

-- =========================================================
-- QA 9: FORECAST EXPLOSION
-- =========================================================

SELECT
    COUNT(DISTINCT mtrl_num) AS affected_materials,
    COUNT(*) AS affected_rows
FROM uspd_analytics_den.analytics_gold.contract_price_forecasted_v2
WHERE forecasted_contract_price > 3 * anchor_contract_price;

-- =========================================================
-- QA 10: NEGATIVE / ZERO FORECAST CHECK
-- =========================================================

SELECT
    COUNT(*) AS total_rows,
    COUNT_IF(forecasted_contract_price <= 0) AS zero_or_negative_rows
FROM uspd_analytics_den.analytics_gold.contract_price_forecasted_v2;

-- =========================================================
-- QA 11: TREND BY SEGMENT
-- =========================================================

SELECT
    cust_segment,
    acct_classification,
    AVG(resolved_monthly_trend_pct) AS avg_trend,
    COUNT(*) AS cnt
FROM uspd_analytics_den.analytics_gold.contract_price_resolved_assumptions_v2
GROUP BY 1,2
ORDER BY cnt DESC;

-- =========================================================
-- QA 12: FULL PIPELINE HEALTH SUMMARY
-- =========================================================

SELECT
    'total_series' AS metric,
    COUNT(DISTINCT CONCAT_WS('|', customer_group_key_id, mtrl_num)) AS value
FROM uspd_analytics_den.analytics_gold.contract_price_resolved_assumptions_v2

UNION ALL

SELECT
    'fallback_pct',
    COUNT_IF(trend_source <> 'MATERIAL') * 1.0 / COUNT(*)
FROM uspd_analytics_den.analytics_gold.contract_price_resolved_assumptions_v2

UNION ALL

SELECT
    'avg_trend',
    AVG(resolved_monthly_trend_pct)
FROM uspd_analytics_den.analytics_gold.contract_price_resolved_assumptions_v2

UNION ALL

SELECT
    'p95_5yr_growth',
    percentile_approx(
        forecasted_contract_price / NULLIF(anchor_contract_price, 0),
        0.95
    )
FROM uspd_analytics_den.analytics_gold.contract_price_forecasted_v2
WHERE forecast_horizon_month_num = 60;




