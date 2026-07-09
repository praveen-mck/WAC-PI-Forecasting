
-- =========================================================
-- STEP 7: FORECAST
-- - Applies forecast_start_contract_price + 0 trend across
--   all 60 future months
-- - Joins material assumptions for full descriptor context
-- - forecast_start_contract_price is the v12 price anchor:
--     prior 12m avg (>= 6 months) -> latest observed avg (>= 6) -> last price
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_forecast_v12 AS
SELECT
    fm.HYBRID_MODEL_KEY_3T,
    fm.mtrl_num,
    fm.anchor_month,
    fm.forecast_month,
    fm.forecast_horizon_month_num,
    fm.forecast_year_month,

    -- tier metadata
    ma.MODEL_TIER,
    ma.sap_months,
    ma.l2_months,
    ma.sap_to_l2_coverage_ratio,

    -- backward-compatible descriptor
    ma.customer_group_key_id,
    ma.customer_group_key_desc,

    -- series descriptors
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

    -- anchor and forecast start price
    ma.anchor_contract_price,
    ma.anchor_wac_spread,
    ma.forecast_start_contract_price,
    ma.forecast_start_wac_spread,
    ma.forecast_start_price_source,

    -- Derived inline (columns not yet materialized in upstream table)
    CASE
        WHEN ma.latest_12_observed_months >= 6  THEN 'PRICE_6MO_AVG'
        WHEN ma.latest_12_observed_months >= 3  THEN 'PRICE_3_TO_5_MO_AVG'
        WHEN ma.latest_12_observed_months >= 1  THEN 'PRICE_LAST_OBSERVED'
        ELSE 'NO_PRICE_AVAILABLE'
    END                                                 AS sparse_price_confidence,

    CASE
        WHEN ma.latest_12_observed_months < 6 THEN 1
        ELSE 0
    END                                                 AS is_sparse_price_flag,

    -- history depth diagnostics
    ma.recent_12m_months,
    ma.prior_12m_months,
    ma.latest_12_observed_months,
    ma.latest_12_observed_start_month,
    ma.latest_12_observed_end_month,

    -- trend = 0 for all series (v12 design)
    ma.expected_monthly_trend_pct,
    ma.material_trend_source,

    -- =====================================================
    -- Forecasted contract price
    -- Compounds from forecast_start_contract_price.
    -- With 0 trend, POWER(1+0, n) = 1 so forecast is flat.
    -- GREATEST guards against floating point negatives.
    -- =====================================================
    CASE
        WHEN ma.forecast_start_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ma.forecast_start_contract_price
            * POWER(
                1 + COALESCE(ma.expected_monthly_trend_pct, 0),
                fm.forecast_horizon_month_num
            ),
            0
        )
    END                                                 AS forecasted_contract_price,

    -- =====================================================
    -- Forecasted WAC spread
    -- Held flat at forecast_start_wac_spread (no trend applied)
    -- =====================================================
    ma.forecast_start_wac_spread                        AS forecasted_wac_spread,

    -- =====================================================
    -- Implied forecasted net cost
    -- = forecasted price * latest observed avg qty
    -- Useful for dollar-level planning; qty held flat at
    -- latest observed average since qty is not modeled here
    -- =====================================================
    CASE
        WHEN ma.forecast_start_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ma.forecast_start_contract_price
            * POWER(
                1 + COALESCE(ma.expected_monthly_trend_pct, 0),
                fm.forecast_horizon_month_num
            ),
            0
        ) * COALESCE(ma.forecast_start_total_sls_qty, 0)
    END                                                 AS forecasted_net_cos

FROM uspd_analytics_den.analytics_gold.contract_price_future_months_v12 fm
JOIN uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v12 ma
  ON fm.HYBRID_MODEL_KEY_3T = ma.HYBRID_MODEL_KEY_3T
 AND fm.mtrl_num             = ma.mtrl_num
;