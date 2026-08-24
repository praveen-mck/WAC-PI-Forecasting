-- -- -- -- -- -- Does modeling_base itself have duplicate groupby_key + month rows
-- -- -- -- -- -- for the two affected keys? Check what differs between them.
-- -- -- -- -- SELECT
-- -- -- -- --     groupby_key,
-- -- -- -- --     cal_month_start_dt,
-- -- -- -- --     contract_price,
-- -- -- -- --     total_net_cos,
-- -- -- -- --     total_sls_qty,
-- -- -- -- --     sap_months,
-- -- -- -- --     l2_months,
-- -- -- -- --     subset_l2_id_resolved,
-- -- -- -- --     exclude_from_training_flag,
-- -- -- -- --     regime_change_type
-- -- -- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
-- -- -- -- -- WHERE groupby_key IN (
-- -- -- -- --     '275088|1619980|340B-CP|CP&H|BX|29205|498814',
-- -- -- -- --     '275088|3423811|340B-CP|CP&H|APOLLO|06473|498814'
-- -- -- -- -- )
-- -- -- -- -- ORDER BY groupby_key, cal_month_start_dt, contract_price;

-- -- -- -- -- Does modeling_base itself have duplicate groupby_key + month rows
-- -- -- -- -- for the two affected keys? Check what differs between them.
-- -- -- -- SELECT
-- -- -- --     groupby_key,
-- -- -- --     cal_month_start_dt,
-- -- -- --     contract_price,
-- -- -- --     total_net_cos,
-- -- -- --     total_sls_qty,
-- -- -- --     sap_months,
-- -- -- --     l2_months,
-- -- -- --     subset_l2_id_resolved,
-- -- -- --     exclude_from_training_flag,
-- -- -- --     regime_change_type
-- -- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
-- -- -- -- WHERE groupby_key IN (
-- -- -- --     '275088|1619980|340B-CP|CP&H|BX|29205|498814',
-- -- -- --     '275088|3423811|340B-CP|CP&H|APOLLO|06473|498814'
-- -- -- -- )
-- -- -- -- ORDER BY groupby_key, cal_month_start_dt, contract_price;



-- -- -- -- ══════════════════════════════════════════════════════════════════
-- -- -- -- OUTSTANDING ISSUES FROM EARLIER QA
-- -- -- -- ══════════════════════════════════════════════════════════════════

-- -- -- -- 1. Remaining 35 duplicate rows in modeling_base
-- -- -- -- (Q1a showed 35 after mixed_regime_flag fix — find the source)
-- -- -- SELECT
-- -- --     groupby_key,
-- -- --     cal_month_start_dt,
-- -- --     COUNT(*)                                            AS cnt,
-- -- --     MIN(contract_price)                                 AS min_cp,
-- -- --     MAX(contract_price)                                 AS max_cp,
-- -- --     MIN(regime_change_type)                             AS regime_1,
-- -- --     MAX(regime_change_type)                             AS regime_2,
-- -- --     MIN(exclude_from_training_flag)                     AS excl_train_min,
-- -- --     MAX(exclude_from_training_flag)                     AS excl_train_max
-- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
-- -- -- GROUP BY groupby_key, cal_month_start_dt
-- -- -- HAVING COUNT(*) > 1;

-- -- -- -- 2. UNKNOWN category — 481K keys with NULL acct_classification
-- -- -- -- These get NO_TREND and fall through all routing. Understand the source.
-- -- -- SELECT
-- -- --     cust_prod_category,
-- -- --     COUNT(DISTINCT groupby_key)                         AS key_count,
-- -- --     COUNT(*)                                            AS row_count
-- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- -- -- WHERE acct_classification IS NULL
-- -- -- GROUP BY cust_prod_category
-- -- -- ORDER BY key_count DESC;

-- -- -- -- 3. PF/MFR trend stddev in thousands for APOLLO
-- -- -- -- avg_yoy_pct stddev of 119,577% for APOLLO AVG_YOY is extreme.
-- -- -- -- These are likely unit price drugs ($0.01, $0.60) where YOY pct
-- -- -- -- swings wildly. Check if they're causing any forecast quality issues.
-- -- -- SELECT
-- -- --     run_id,
-- -- --     groupby_key,
-- -- --     avg_yoy_pct,
-- -- --     yoy_pairs_used,
-- -- --     anchor_contract_price,
-- -- --     forecast_start_contract_price,
-- -- --     expected_monthly_trend_pct,
-- -- --     assigned_trend_method
-- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- -- -- WHERE cust_prod_category = 'APOLLO'
-- -- --   AND ABS(avg_yoy_pct) > 1.0          -- > 100% YOY swing
-- -- -- ORDER BY ABS(avg_yoy_pct) DESC
-- -- -- LIMIT 20;

-- -- -- -- ══════════════════════════════════════════════════════════════════
-- -- -- -- REGRESSION QUALITY GUARD VALIDATION
-- -- -- -- ══════════════════════════════════════════════════════════════════

-- -- -- -- 4. How many keys did the regression guard demote to NO_TREND?
-- -- -- -- Break out by category and which guard condition failed.
-- -- -- SELECT
-- -- --     cust_prod_category,
-- -- --     acct_classification,
-- -- --     CASE
-- -- --         WHEN COALESCE(regression_quarters_used, 0) < 3          THEN 'insufficient_quarters'
-- -- --         WHEN COALESCE(directional_consistency, 0) < 0.60        THEN 'low_directional_consistency'
-- -- --         WHEN ABS(raw_regression_trend_pct) > 0.15               THEN 'extreme_slope'
-- -- --         ELSE 'unknown'
-- -- --     END                                                         AS guard_failure_reason,
-- -- --     COUNT(DISTINCT groupby_key)                                 AS demoted_key_count,
-- -- --     ROUND(AVG(regression_quarters_used), 1)                     AS avg_quarters,
-- -- --     ROUND(AVG(directional_consistency), 3)                      AS avg_dir_consistency,
-- -- --     ROUND(AVG(ABS(raw_regression_trend_pct)) * 100, 2)         AS avg_abs_slope_pct
-- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- -- -- WHERE assigned_trend_method = 'NO_TREND'
-- -- --   AND raw_regression_trend_pct != 0          -- had a regression signal but was demoted
-- -- --   AND acct_classification IN ('340B-CP','340B-CE')
-- -- --   AND cust_prod_category NOT IN ('APOLLO','GLP-1','MPB Specialty','MPB Plasma')
-- -- -- GROUP BY 1, 2, 3
-- -- -- ORDER BY demoted_key_count DESC;

-- -- -- -- ══════════════════════════════════════════════════════════════════
-- -- -- -- FORECAST QUALITY SUMMARY
-- -- -- -- ══════════════════════════════════════════════════════════════════

-- -- -- -- 5. Pass rate trend across BT runs by category
-- -- -- -- Expect improvement from BT_2024_01 → BT_2025_01 as more history
-- -- -- -- becomes available and fixes take effect.
-- -- -- SELECT
-- -- --     run_id,
-- -- --     cust_prod_category,
-- -- --     SUM(series_cnt)                                             AS series_cnt,
-- -- --     ROUND(SUM(actual_dollars) / 1e6, 0)                        AS actual_mm,
-- -- --     ROUND(SUM(error_dollars)
-- -- --           / NULLIF(SUM(actual_dollars), 0) * 100, 2)           AS bias_pct,
-- -- --     ROUND(SUM(wmape * actual_dollars)
-- -- --           / NULLIF(SUM(actual_dollars), 0) * 100, 2)           AS weighted_wmape_pct,
-- -- --     ROUND(SUM(pass_cnt_materiality)
-- -- --           / NULLIF(SUM(series_cnt), 0) * 100, 1)               AS pass_rate_pct,
-- -- --     ROUND(SUM(pass_cnt_top100)
-- -- --           / NULLIF(SUM(series_cnt), 0) * 100, 1)               AS top100_pass_rate_pct
-- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
-- -- -- GROUP BY run_id, cust_prod_category
-- -- -- ORDER BY run_id, SUM(actual_dollars) DESC;

-- -- -- -- 6. Step history performance vs AVG_YOY for APOLLO and BX
-- -- -- -- Validates that STEP_UP/DOWN_HISTORY is actually better than falling
-- -- -- -- through to AVG_YOY. If not, the step history feature is net negative.
-- -- -- SELECT
-- -- --     cust_prod_category,
-- -- --     trend_source,
-- -- --     COUNT(DISTINCT groupby_key)                                 AS key_count,
-- -- --     ROUND(SUM(actual_dollars) / 1e6, 1)                        AS actual_mm,
-- -- --     ROUND(SUM(error_dollars)
-- -- --           / NULLIF(SUM(actual_dollars), 0) * 100, 2)           AS bias_pct,
-- -- --     ROUND(SUM(ABS(forecasted_contract_price - actual_contract_price)
-- -- --               * actual_sls_qty)
-- -- --           / NULLIF(SUM(ABS(actual_contract_price) * actual_sls_qty), 0)
-- -- --           * 100, 2)                                             AS wmape_pct
-- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
-- -- -- WHERE cust_prod_category IN ('APOLLO', 'BX')
-- -- --   AND trend_source IN ('STEP_UP_HISTORY','STEP_DOWN_HISTORY','AVG_YOY','PF_AVG_YOY','NO_TREND')
-- -- --   AND actual_contract_price IS NOT NULL
-- -- -- GROUP BY cust_prod_category, trend_source
-- -- -- ORDER BY cust_prod_category, wmape_pct;

-- -- -- -- 7. 3x cap fire rate by source — confirm cap is not over-firing
-- -- -- -- on legitimate prices (should be rare for most sources)
-- -- -- SELECT
-- -- --     cust_prod_category,
-- -- --     forecast_start_price_source,
-- -- --     SUM(forecast_start_price_capped_flag)                       AS capped_rows,
-- -- --     COUNT(*)                                                    AS total_rows,
-- -- --     ROUND(SUM(forecast_start_price_capped_flag)
-- -- --           / NULLIF(COUNT(*), 0) * 100, 2)                      AS cap_fire_pct,
-- -- --     ROUND(AVG(CASE WHEN forecast_start_price_capped_flag = 1
-- -- --                    THEN anchor_contract_price END), 2)          AS avg_anchor_when_capped
-- -- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- -- -- WHERE forecast_start_price_capped_flag = 1
-- -- -- GROUP BY cust_prod_category, forecast_start_price_source
-- -- -- ORDER BY capped_rows DESC
-- -- -- LIMIT 20;

-- -- -- ══════════════════════════════════════════════════════════════════
-- -- -- STEP HISTORY CHANGE VALIDATION
-- -- -- Compare step history vs fallback methods after:
-- -- --   - APOLLO step_up_count >= 2 (was >= 1)
-- -- --   - APOLLO STEP_DOWN_HISTORY disabled
-- -- --   - BX STEP_DOWN_HISTORY disabled
-- -- -- ══════════════════════════════════════════════════════════════════

-- -- -- Q1: Method distribution shift — how many keys moved from
-- -- -- STEP_UP_HISTORY to AVG_YOY due to step_up_count >= 2 tightening?
-- -- SELECT
-- --     cust_prod_category,
-- --     assigned_trend_method,
-- --     COUNT(DISTINCT groupby_key)                         AS key_count,
-- --     ROUND(AVG(step_up_count), 1)                        AS avg_step_up_count,
-- --     ROUND(AVG(expected_monthly_trend_pct) * 100, 3)    AS avg_trend_pct,
-- --     ROUND(AVG(directional_consistency), 3)              AS avg_dir_consistency
-- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- -- WHERE cust_prod_category IN ('APOLLO', 'BX')
-- --   AND assigned_trend_method IN (
-- --       'STEP_UP_HISTORY', 'AVG_YOY', 'PF_AVG_YOY',
-- --       'MFR_AVG_YOY', 'NO_TREND', 'SIGN_ONLY_025PCT', 'AVG_YOY_PROMOTED'
-- --   )
-- -- GROUP BY cust_prod_category, assigned_trend_method
-- -- ORDER BY cust_prod_category, key_count DESC;

-- -- -- Q2: Core performance comparison — WMAPE and bias by method
-- -- -- Primary validation that step history changes improved accuracy.
-- -- -- Expected: APOLLO STEP_UP_HISTORY WMAPE should now be closer to
-- -- -- or better than AVG_YOY (was 3.08% vs 2.68%).
-- -- SELECT
-- --     cust_prod_category,
-- --     trend_source,
-- --     COUNT(DISTINCT groupby_key)                         AS key_count,
-- --     ROUND(SUM(actual_dollars) / 1e6, 1)                AS actual_mm,
-- --     ROUND(SUM(error_dollars)
-- --           / NULLIF(SUM(actual_dollars), 0) * 100, 2)   AS bias_pct,
-- --     ROUND(SUM(ABS(forecasted_contract_price - actual_contract_price)
-- --               * actual_sls_qty)
-- --           / NULLIF(SUM(ABS(actual_contract_price)
-- --               * actual_sls_qty), 0) * 100, 2)          AS wmape_pct,
-- --     ROUND(AVG(resolved_monthly_trend_pct) * 100, 3)    AS avg_trend_pct
-- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
-- -- WHERE cust_prod_category IN ('APOLLO', 'BX')
-- --   AND trend_source IN (
-- --       'STEP_UP_HISTORY', 'STEP_DOWN_HISTORY',
-- --       'AVG_YOY', 'PF_AVG_YOY', 'NO_TREND',
-- --       'SIGN_ONLY_025PCT', 'AVG_YOY_PROMOTED'
-- --   )
-- --   AND actual_contract_price IS NOT NULL
-- -- GROUP BY cust_prod_category, trend_source
-- -- ORDER BY cust_prod_category, wmape_pct;

-- -- -- Q3: Overall APOLLO and BX summary vs prior run
-- -- -- Compare pass_rate and WMAPE at segment level.
-- -- SELECT
-- --     run_id,
-- --     cust_prod_category,
-- --     trend_cap_applied,
-- --     SUM(series_cnt)                                     AS series_cnt,
-- --     ROUND(SUM(actual_dollars) / 1e6, 0)                AS actual_mm,
-- --     ROUND(SUM(error_dollars)
-- --           / NULLIF(SUM(actual_dollars), 0) * 100, 2)   AS bias_pct,
-- --     ROUND(SUM(wmape * actual_dollars)
-- --           / NULLIF(SUM(actual_dollars), 0) * 100, 2)   AS weighted_wmape_pct,
-- --     ROUND(SUM(pass_cnt_materiality)
-- --           / NULLIF(SUM(series_cnt), 0) * 100, 1)       AS pass_rate_pct,
-- --     ROUND(SUM(pass_cnt_top100)
-- --           / NULLIF(SUM(series_cnt), 0) * 100, 1)       AS top100_pass_rate_pct
-- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
-- -- WHERE cust_prod_category IN ('APOLLO', 'BX')
-- -- GROUP BY run_id, cust_prod_category, trend_cap_applied
-- -- ORDER BY run_id, cust_prod_category;

-- -- -- Q4: Keys that previously had only 1 step-up (now demoted from
-- -- -- STEP_UP_HISTORY to AVG_YOY) — confirm they get a reasonable trend.
-- -- -- These keys had step_up_count = 1 before and would have been
-- -- -- STEP_UP_HISTORY; now they fall through to avg_yoy_pct.
-- -- SELECT
-- --     cust_prod_category,
-- --     assigned_trend_method,
-- --     step_up_count,
-- --     COUNT(DISTINCT groupby_key)                         AS key_count,
-- --     ROUND(AVG(expected_monthly_trend_pct) * 100, 3)    AS avg_trend_pct,
-- --     ROUND(AVG(avg_yoy_pct) * 100, 3)                   AS avg_yoy_pct,
-- --     ROUND(AVG(avg_step_up_pct) * 100, 3)               AS avg_step_up_pct
-- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- -- WHERE cust_prod_category IN ('APOLLO', 'BX')
-- --   AND step_up_count = 1                 -- keys that would have fired before
-- -- GROUP BY cust_prod_category, assigned_trend_method, step_up_count
-- -- ORDER BY cust_prod_category, key_count DESC;

-- -- -- Q5: Confirm no STEP_DOWN_HISTORY remains in output
-- -- -- Should return 0 rows for both APOLLO and BX.
-- -- SELECT
-- --     cust_prod_category,
-- --     assigned_trend_method,
-- --     COUNT(*) AS row_count
-- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- -- WHERE assigned_trend_method = 'STEP_DOWN_HISTORY'
-- -- GROUP BY cust_prod_category, assigned_trend_method;

-- -- -- Q6: SKYRIZI PEN spot-check — the original failing key.
-- -- -- Should now show STEP_UP_HISTORY only if step_up_count >= 2,
-- -- -- otherwise AVG_YOY. BT_2025_01 had step_up_count = 4 so should
-- -- -- still fire as STEP_UP_HISTORY at the corrected direction.
-- -- SELECT
-- --     run_id,
-- --     assigned_trend_method,
-- --     expected_monthly_trend_pct,
-- --     step_up_count,
-- --     step_down_count,
-- --     last_step_direction,
-- --     avg_yoy_pct,
-- --     directional_consistency,
-- --     forecast_start_contract_price
-- -- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- -- WHERE groupby_key = '755781|2324978|Retail|SNA|APOLLO|00152|945'
-- -- ORDER BY run_id;

-- SELECT
--     run_id,
--     groupby_key,
--     step_up_count,
--     assigned_trend_method,
--     acct_classification,
--     product_family
-- FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
-- WHERE cust_prod_category = 'BX'
--   AND assigned_trend_method = 'STEP_UP_HISTORY'
--   AND step_up_count = 1
-- LIMIT 5;

-- ══════════════════════════════════════════════════════════════════
-- 1. AVG_YOY_PROMOTED formula change validation
-- XARELTO should now show ~5% trend instead of ~0.9%
-- Keys with dc=1.0 should get full avg_yoy_pct
-- Keys with 0.80 <= dc < 1.0 should still get * 0.19
-- ══════════════════════════════════════════════════════════════════
SELECT
    cust_prod_category,
    assigned_trend_method,
    ROUND(AVG(directional_consistency), 3)              AS avg_dc,
    ROUND(AVG(avg_yoy_pct) * 100, 3)                   AS avg_raw_yoy_pct,
    ROUND(AVG(expected_monthly_trend_pct) * 100, 3)    AS avg_applied_trend_pct,
    ROUND(AVG(expected_monthly_trend_pct)
          / NULLIF(AVG(avg_yoy_pct), 0), 3)            AS effective_multiplier,
    COUNT(DISTINCT groupby_key)                         AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
WHERE assigned_trend_method = 'AVG_YOY_PROMOTED'
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category;
-- Expect: effective_multiplier ~1.0 for keys with dc=1.0 dominant segments
-- and ~0.19 for segments with mixed directional consistency

-- XARELTO spot-check
SELECT
    run_id,
    assigned_trend_method,
    expected_monthly_trend_pct,
    avg_yoy_pct,
    directional_consistency,
    ROUND(expected_monthly_trend_pct / NULLIF(avg_yoy_pct, 0), 3) AS multiplier_applied
FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
WHERE groupby_key IN (
    '952635|1413756|Retail|SNA|BX|23152|816',
    '952635|3748316|Retail|SNA|BX|23152|816'
)
ORDER BY groupby_key, run_id;
-- Expect: multiplier_applied = 1.0 for BT_2025_01 (dc=1.0, avg_yoy ~5%)

-- ══════════════════════════════════════════════════════════════════
-- 2. YOY sanity filter validation
-- avg_yoy_pct should now be NULL or <= 500% for all keys
-- ══════════════════════════════════════════════════════════════════
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key)                         AS key_count,
    ROUND(AVG(avg_yoy_pct) * 100, 2)                   AS avg_yoy_pct,
    ROUND(MAX(ABS(avg_yoy_pct)) * 100, 0)              AS max_abs_yoy_pct,
    SUM(CASE WHEN ABS(avg_yoy_pct) > 5.0 THEN 1 ELSE 0 END)
                                                        AS keys_over_500pct
FROM uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23
WHERE avg_yoy_pct IS NOT NULL
GROUP BY cust_prod_category, assigned_trend_method
HAVING MAX(ABS(avg_yoy_pct)) > 1.0      -- focus on non-trivial values
ORDER BY max_abs_yoy_pct DESC
LIMIT 20;
-- Expect: max_abs_yoy_pct <= 500% everywhere, keys_over_500pct = 0

-- ══════════════════════════════════════════════════════════════════
-- 3. Overall performance after all changes
-- Final summary across all BT runs and segments
-- ══════════════════════════════════════════════════════════════════
SELECT
    run_id,
    cust_prod_category,
    SUM(series_cnt)                                     AS series_cnt,
    ROUND(SUM(actual_dollars) / 1e6, 0)                AS actual_mm,
    ROUND(SUM(error_dollars)
          / NULLIF(SUM(actual_dollars), 0) * 100, 2)   AS bias_pct,
    ROUND(SUM(wmape * actual_dollars)
          / NULLIF(SUM(actual_dollars), 0) * 100, 2)   AS weighted_wmape_pct,
    ROUND(SUM(pass_cnt_materiality)
          / NULLIF(SUM(series_cnt), 0) * 100, 1)       AS pass_rate_pct,
    ROUND(SUM(pass_cnt_top100)
          / NULLIF(SUM(series_cnt), 0) * 100, 1)       AS top100_pass_rate_pct,
    SUM(explosion_cnt)                                  AS explosion_cnt
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
GROUP BY run_id, cust_prod_category
ORDER BY run_id, SUM(actual_dollars) DESC;

-- ══════════════════════════════════════════════════════════════════
-- 4. AVG_YOY_PROMOTED performance — did full rate improve accuracy?
-- ══════════════════════════════════════════════════════════════════
SELECT
    cust_prod_category,
    trend_source,
    COUNT(DISTINCT groupby_key)                         AS key_count,
    ROUND(SUM(actual_dollars) / 1e6, 1)                AS actual_mm,
    ROUND(SUM(error_dollars)
          / NULLIF(SUM(actual_dollars), 0) * 100, 2)   AS bias_pct,
    ROUND(SUM(ABS(forecasted_contract_price - actual_contract_price)
              * actual_sls_qty)
          / NULLIF(SUM(ABS(actual_contract_price)
              * actual_sls_qty), 0) * 100, 2)          AS wmape_pct
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
WHERE trend_source = 'AVG_YOY_PROMOTED'
  AND actual_contract_price IS NOT NULL
GROUP BY cust_prod_category, trend_source
ORDER BY actual_mm DESC;
-- Compare to prior: BX AVG_YOY_PROMOTED was 12.85% WMAPE
-- Expect improvement since dc=1.0 keys now use full rate

-- ══════════════════════════════════════════════════════════════════
-- 5. Final explosion check — confirm still 0 after all rebuilds
-- ══════════════════════════════════════════════════════════════════
SELECT
    cust_prod_category,
    trend_cap_applied,
    SUM(explosion_cnt)                                  AS total_explosions,
    SUM(series_cnt)                                     AS total_series
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
GROUP BY cust_prod_category, trend_cap_applied
HAVING SUM(explosion_cnt) > 0
ORDER BY total_explosions DESC;
-- Expect: no rows returned