/* =====================================================================
   CONTRACT PRICE LIVE FORECAST PIPELINE v23 — STEPS 5b ONWARD
   ---------------------------------------------------------------------
   Prerequisites: Steps 1–3 must be run first (same as BT).
     Step 1  — contract_price_modeling_base_v23
     Step 2  — contract_price_history_profile_v23
     Step 3  — contract_price_training_clean_v23
     Step 4  — contract_price_material_live_assumptions_v23  ← run first

   Also requires live equivalents of BT lookup tables:
     contract_price_last_actual_v23       (no _bt_ prefix)
     contract_price_latest_obs_v23        (no _bt_ prefix)

   Key differences from BT pipeline:
     No run_id — one row per groupby_key
     No point-in-time caps — uses full history
     jump_off_month = MAX(cal_month_start_dt) in modeling_base
     No eval vs actuals (no actuals exist for future months)

   This file runs:
     Step 5b — contract_price_live_resolved_assumptions_v23
     Step 7  — contract_price_live_future_months_v23
     Step 8  — contract_price_live_forecasted_v23
   ===================================================================== */


-- =====================================================================
-- JUMP-OFF DATE
-- Used across Steps 5b, 7, 8. Derived once here as a scalar subquery.
-- Override by replacing MAX(cal_month_start_dt) with DATE '2025-06-01'
-- =====================================================================


-- =====================================================================
-- STEP 5b (LIVE): RESOLVED ASSUMPTIONS
-- Joins Step 4 live output to last_actual for anchor and WAC context.
-- No eligibility table — uses all keys from Step 4 directly.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_live_resolved_assumptions_v23 AS
SELECT
    ma.groupby_key,
    -- Jump-off month: latest available month in modeling_base
    (SELECT MAX(cal_month_start_dt)
     FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
     WHERE exclude_from_training_flag = 0)              AS jump_off_month,
    ma.acct_classification,
    ma.cust_prod_category,
    ma.product_family,
    ma.manufacturer_id,
    hp.sap_cust_num_trim,
    hp.mtrl_num,
    hp.cust_segment,
    hp.national_grp_id,
    hp.national_grp_desc,
    hp.common_grp_id,
    hp.common_grp_desc,
    hp.subset_l2_id_resolved,
    hp.mtrl_nme_nvgton,
    hp.ndc_num,
    hp.therapeutic_class,
    hp.manufacturer_name,
    hp.final_product_group,
    -- WAC and total_net_revenue sourced in Step 8 from modeling_base at jump_off
    la.anchor_wac_weighted                              AS WAC,
    hp.top_100_brand_flag,
    hp.brand_wac_rank,
    hp.first_month,
    la.anchor_month,
    DATEDIFF(MONTH, hp.first_month,
        (SELECT MAX(cal_month_start_dt)
         FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
         WHERE exclude_from_training_flag = 0)
    )                                                   AS months_since_first_asof_jumpoff,
    la.anchor_contract_price,
    la.anchor_wac_weighted,
    la.anchor_wac_spread,
    la.anchor_total_sls_qty,
    la.anchor_total_net_cos,
    ma.forecast_start_contract_price,
    ma.forecast_start_wac_spread,
    ma.forecast_start_price_source,
    ma.forecast_start_price_capped_flag,
    ma.sparse_price_confidence,
    ma.is_sparse_price_flag,
    ma.recent_6m_months,
    ma.latest_6_observed_months,
    ma.expected_monthly_trend_pct                       AS resolved_monthly_trend_pct,
    ma.assigned_trend_method                            AS trend_source,
    ma.trend_cap_applied,
    ma.typical_increase_month,
    -- Step history diagnostics
    ma.step_up_count,
    ma.avg_step_up_pct,
    ma.step_down_count,
    ma.avg_step_down_pct,
    ma.last_step_direction,
    ma.recent_wac_avg_mom_change,
    -- Trend diagnostics
    ma.yoy_pairs_used,
    ma.avg_yoy_pct,
    ma.directional_consistency,
    ma.raw_regression_trend_pct,
    ma.regression_quarters_used,
    ma.pf_yoy_pairs_used,
    ma.pf_avg_yoy_pct,
    ma.mfr_yoy_pairs_used,
    ma.mfr_avg_yoy_pct,
    ma.sign_only_eligible,
    ma.g5_recent_price_not_falling
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23 ma
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_last_actual_v23 la
  ON ma.groupby_key = la.groupby_key
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_history_profile_v23 hp
  ON ma.groupby_key = hp.groupby_key
WHERE la.anchor_contract_price IS NOT NULL
;
