-- =========================================================
-- STEP 7: FORECAST OUTPUT v21
--
-- Changes from v20:
--   - Table references updated to v21
--   - HYBRID_MODEL_KEY_3T replaced with sap_cust_num_trim
--     as the series key in SELECT, JOIN ON clauses,
--     and the WAC/net_revenue subquery GROUP BY
--   - MODEL_TIER removed; sap_months/l2_months informational
--   - sparse_price_confidence and is_sparse_price_flag
--     sourced directly from material_assumptions_v21
--     (pre-computed there; derived inline logic removed)
--   - avg_yoy_pct standardized name carried forward
-- groupby_key as join key; all renamed calendar/fiscal cols
-- =========================================================
 
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_forecast_v21 AS
SELECT
    fm.groupby_key,
    fm.sap_cust_num_trim,
    fm.mtrl_num,
    fm.anchor_month,
    fm.jump_off_dt,
    fm.forecast_month,
    fm.forecast_horizon_month_num,
    fm.forecast_cal_year_month,
    fm.forecast_fiscal_year_month,
    fm.forecast_year_num,
 
    ma.sap_months,
    ma.l2_months,
    ma.sap_to_l2_coverage_ratio,
    ma.cust_segment,
    ma.acct_classification,
    ma.cust_prod_category,
    ma.national_grp_id,
    ma.national_grp_desc,
    ma.common_grp_id,
    ma.common_grp_desc,
    ma.subset_l2_id_resolved,
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
    ma.sparse_price_confidence,
    ma.is_sparse_price_flag,
    ma.recent_6m_months,
    ma.prior_6m_months,
    ma.latest_6_observed_months,
    ma.latest_6_observed_start_month,
    ma.latest_6_observed_end_month,
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
            ), 0)
    END                                                 AS forecasted_contract_price,
 
    ma.forecast_start_wac_spread                        AS forecasted_wac_spread,
 
    CASE
        WHEN ma.forecast_start_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ma.forecast_start_contract_price
            * POWER(
                1 + COALESCE(ma.expected_monthly_trend_pct, 0),
                CEIL(fm.forecast_horizon_month_num / 3.0)
            ), 0) * COALESCE(ma.forecast_start_total_sls_qty, 0)
    END                                                 AS forecasted_net_cos
 
FROM uspd_analytics_den.analytics_gold.contract_price_future_months_v21 fm
JOIN uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v21 ma
  ON fm.groupby_key = ma.groupby_key
;
 