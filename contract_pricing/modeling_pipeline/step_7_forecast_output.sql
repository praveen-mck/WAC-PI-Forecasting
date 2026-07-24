-- =========================================================
-- STEP 7: FORECAST OUTPUT v19
-- Changes from v18:
--   - Table references updated to v19
--   - avg_yoy_pct standardized name reflected in comments
--   - sparse_price_confidence and is_sparse_price_flag
--     sourced directly from material_assumptions_v19
--     (pre-computed there; derived inline logic removed)
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_forecast_v19 AS
SELECT
    fm.HYBRID_MODEL_KEY_3T,
    fm.mtrl_num,
    fm.anchor_month,
    fm.forecast_month,
    fm.forecast_horizon_month_num,
    fm.forecast_year_month,

    ma.MODEL_TIER,
    ma.sap_months,
    ma.l2_months,
    ma.sap_to_l2_coverage_ratio,

    ma.cust_segment,
    ma.acct_classification,
    ma.cust_prod_category,
    ma.national_grp_id,
    ma.national_grp_desc,
    ma.mtrl_nme_nvgton,
    ma.ndc_num,
    ma.product_family,
    ma.therapeutic_class,
    ma.manufacturer_id,
    ma.manufacturer_name,
    ma.final_product_group,
    ma.final_product_group_level,

    ma.anchor_contract_price,
    ma.anchor_wac_spread,
    ma.forecast_start_contract_price,
    ma.forecast_start_wac_spread,
    ma.forecast_start_price_source,

    -- sparse_price_confidence and is_sparse_price_flag sourced
    -- directly from assumptions (pre-computed in step 4).
    ma.sparse_price_confidence,
    ma.is_sparse_price_flag,

    ma.recent_6m_months,
    ma.prior_6m_months,
    ma.latest_6_observed_months,
    ma.latest_6_observed_start_month,
    ma.latest_6_observed_end_month,

    -- avg_yoy_pct: standardized name (was raw_avg_yoy_trend_pct in v18)
    ma.avg_yoy_pct,
    ma.expected_monthly_trend_pct,
    ma.material_trend_source,

    CASE
        WHEN ma.forecast_start_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ma.forecast_start_contract_price
            * POWER(
                1 + COALESCE(ma.expected_monthly_trend_pct, 0),
                CEIL(fm.forecast_horizon_month_num / 3.0)
            ),
            0
        )
    END                                                 AS forecasted_contract_price,

    ma.forecast_start_wac_spread                        AS forecasted_wac_spread,

    CASE
        WHEN ma.forecast_start_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ma.forecast_start_contract_price
            * POWER(
                1 + COALESCE(ma.expected_monthly_trend_pct, 0),
                CEIL(fm.forecast_horizon_month_num / 3.0)
            ),
            0
        ) * COALESCE(ma.forecast_start_total_sls_qty, 0)
    END                                                 AS forecasted_net_cos

FROM uspd_analytics_den.analytics_gold.contract_price_future_months_v19 fm
JOIN uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v19 ma
  ON fm.HYBRID_MODEL_KEY_3T = ma.HYBRID_MODEL_KEY_3T
 AND fm.mtrl_num             = ma.mtrl_num
;