-- =========================================================
-- QA SCRIPT — CONTRACT PRICE MODELING PIPELINE v23
-- Covers Steps 1–7 in execution order.
-- Run each section after the corresponding step completes.
-- All checks target v23 tables using groupby_key grain.
--
-- Pass criteria noted inline; flag any result != expected.
-- =========================================================


-- =============================================================
-- STEP 1 QA: contract_price_modeling_base_v23
-- =============================================================

-- S1-1: No duplicate rows at grain (groupby_key + month).
-- Expected: 0 rows returned.
SELECT groupby_key, cal_month_start_dt, COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
GROUP BY groupby_key, cal_month_start_dt
HAVING COUNT(*) > 1
ORDER BY row_count DESC
LIMIT 50;

-- S1-2: No negative CONTRACT_PRICE or TOTAL_NET_COS.
-- Expected: bad_rows = 0.
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
WHERE CONTRACT_PRICE < 0
   OR TOTAL_NET_COS < 0;

-- S1-3: Date range matches source filter (2022-01 to 2026-07).
-- Expected: min = 2022-01-01, max = 2026-07-01.
SELECT
    MIN(cal_month_start_dt) AS min_month,
    MAX(cal_month_start_dt) AS max_month,
    COUNT(DISTINCT cal_month_start_dt) AS distinct_months
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23;

-- S1-4: Row and series counts for sizing sanity.
SELECT
    COUNT(*)                                        AS total_rows,
    COUNT(DISTINCT groupby_key)                     AS distinct_series,
    COUNT(DISTINCT MTRL_NUM)                        AS distinct_materials,
    COUNT(DISTINCT sap_cust_num_trim)               AS distinct_customers
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23;

-- S1-5: CUST_PROD_CATEGORY distribution — confirm all expected
-- categories are present and no unexpected values appear.
SELECT
    CUST_PROD_CATEGORY,
    COUNT(DISTINCT groupby_key) AS distinct_series,
    COUNT(*)                    AS total_rows
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
GROUP BY CUST_PROD_CATEGORY
ORDER BY total_rows DESC;

-- S1-6: ACCT_CLASSIFICATION distribution.
-- Expected values: Retail, GPO, WAC, 340B-CE, 340B-CP.
-- No other values should appear.
SELECT
    ACCT_CLASSIFICATION,
    COUNT(DISTINCT groupby_key) AS distinct_series
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
GROUP BY ACCT_CLASSIFICATION
ORDER BY distinct_series DESC;

-- S1-7: WAC_SPREAD NULL rate and out-of-range check.
-- WAC_SPREAD should be non-NULL for most rows (NULL only when WAC=0).
-- Extreme values (< -1 or > 1) warrant review.
SELECT
    SUM(CASE WHEN WAC_SPREAD IS NULL         THEN 1 ELSE 0 END) AS null_wac_spread,
    SUM(CASE WHEN WAC_SPREAD < -1            THEN 1 ELSE 0 END) AS spread_below_neg1,
    SUM(CASE WHEN WAC_SPREAD > 1             THEN 1 ELSE 0 END) AS spread_above_1,
    ROUND(MIN(WAC_SPREAD), 4)                                   AS min_spread,
    ROUND(MAX(WAC_SPREAD), 4)                                   AS max_spread,
    ROUND(AVG(WAC_SPREAD), 4)                                   AS avg_spread
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23;

-- S1-8: Regime change distribution.
-- Expected: NONE = large majority; NORMAL_REGIME_CHANGE ~88k series;
-- EXTREME_REGIME_CHANGE ~27k series (per v23 comment header).
SELECT
    regime_change_type,
    COUNT(DISTINCT groupby_key) AS series_count
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
GROUP BY regime_change_type
ORDER BY series_count DESC;

-- S1-9: mixed_regime_flag match rate for 340B keys.
-- Expected: match_pct > 99%.
-- Low pct indicates groupby_key mismatch in pre-agg CTE (known issue in header).
SELECT
    COUNT(DISTINCT CASE WHEN regime_change_type != 'NONE'
                        THEN groupby_key END)                   AS matched_regime_keys,
    COUNT(DISTINCT CASE WHEN ACCT_CLASSIFICATION IN ('340B-CP','340B-CE')
                        THEN groupby_key END)                   AS total_340b_keys,
    ROUND(
        COUNT(DISTINCT CASE WHEN regime_change_type != 'NONE'
                            THEN groupby_key END)
        / NULLIF(COUNT(DISTINCT CASE WHEN ACCT_CLASSIFICATION IN ('340B-CP','340B-CE')
                                     THEN groupby_key END), 0) * 100, 2
    )                                                           AS match_pct
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
WHERE ACCT_CLASSIFICATION IN ('340B-CP','340B-CE');

-- S1-10: Training exclusion flag breakdown.
-- Validates that exclude_from_training_flag is correctly the union of
-- prelim_exclude_from_training, invalid_wac_flag, and contract_price_outlier_flag.
-- Expected: no row where exclude_from_training_flag=0 but any component flag=1.
SELECT
    exclude_from_training_flag,
    prelim_exclude_from_training,
    invalid_wac_flag,
    contract_price_outlier_flag,
    COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;

-- S1-11: zombie_sale_flag NULL-safety (Fix 8 validation).
-- Expected: bad_rows = 0.
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
WHERE zombie_sale_flag = 1 AND TOTAL_ZOMBIE_SALES IS NULL;

-- S1-12: Contract price above WAC flag — should be 0 for WAC/340B rows.
-- Expected: no rows where contract_price_above_wac_flag=1 and
-- ACCT_CLASSIFICATION IN ('WAC','340B-CP','340B-CE').
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
WHERE contract_price_above_wac_flag = 1
  AND ACCT_CLASSIFICATION IN ('WAC', '340B-CP', '340B-CE');


-- =============================================================
-- STEP 2 QA: contract_price_history_profile_v23
-- =============================================================

-- S2-1: Exactly one row per groupby_key (history profile is a summary table).
-- Expected: 0 rows returned.
SELECT groupby_key, COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23
GROUP BY groupby_key
HAVING COUNT(*) > 1
ORDER BY row_count DESC
LIMIT 20;

-- S2-2: Series count in history profile vs base table.
-- History profile should have fewer distinct keys (only those with
-- exclude_from_training_flag=0 rows in base). A very large drop
-- (> 30%) warrants investigation.
SELECT
    (SELECT COUNT(DISTINCT groupby_key)
     FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
     WHERE exclude_from_training_flag = 0)           AS base_trainable_series,
    (SELECT COUNT(DISTINCT groupby_key)
     FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23)
                                                     AS history_series,
    ROUND(
        (SELECT COUNT(DISTINCT groupby_key)
         FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23)
        * 100.0
        / NULLIF((SELECT COUNT(DISTINCT groupby_key)
                  FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
                  WHERE exclude_from_training_flag = 0), 0),
    2)                                               AS coverage_pct;

-- S2-3: lifecycle_length_months must be >= months_with_history and >= 1.
-- Expected: bad_rows = 0.
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23
WHERE lifecycle_length_months < 1
   OR lifecycle_length_months < months_with_history;

-- S2-4: History bucket distribution. Inspect for unexpected spikes
-- in VERY_LOW_HISTORY (could signal training data loss).
SELECT
    history_bucket,
    COUNT(*) AS key_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23
GROUP BY history_bucket
ORDER BY key_count DESC;

-- S2-5: Top 100 brands — exactly 100 distinct brand_name values should
-- have brand_wac_rank IS NOT NULL. Fix 7 uses quantity-weighted WAC.
SELECT
    COUNT(DISTINCT brand_name)                          AS brands_with_rank,
    MIN(brand_wac_rank)                                 AS min_rank,
    MAX(brand_wac_rank)                                 AS max_rank
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23
WHERE brand_wac_rank IS NOT NULL;

-- S2-6: Top 20 brands by new quantity-weighted WAC rank.
-- Inspect to confirm high-WAC, high-volume brands rank highest (Fix 7).
SELECT brand_name, brand_wac_rank, COUNT(groupby_key) AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23
WHERE brand_wac_rank IS NOT NULL
GROUP BY brand_name, brand_wac_rank
ORDER BY brand_wac_rank
LIMIT 20;

-- S2-7: NULL check on critical fields.
SELECT
    COUNT(*)                                                AS total_keys,
    SUM(CASE WHEN groupby_key          IS NULL THEN 1 ELSE 0 END) AS null_groupby_key,
    SUM(CASE WHEN months_with_history  IS NULL THEN 1 ELSE 0 END) AS null_months_with_history,
    SUM(CASE WHEN avg_contract_price   IS NULL THEN 1 ELSE 0 END) AS null_avg_contract_price,
    SUM(CASE WHEN first_month         IS NULL THEN 1 ELSE 0 END) AS null_first_month,
    SUM(CASE WHEN last_month          IS NULL THEN 1 ELSE 0 END) AS null_last_month
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23;

-- S2-8: avg_contract_price sanity — no zero or negative values.
-- Expected: bad_rows = 0.
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23
WHERE avg_contract_price <= 0;


-- =============================================================
-- STEP 3 QA: contract_price_training_clean_v23
-- =============================================================

-- S3-1: Row count matches base table (training_clean is a row-for-row
-- extension of base, not a filter). Expected: counts equal.
SELECT
    (SELECT COUNT(*) FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23)
        AS base_rows,
    (SELECT COUNT(*) FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23)
        AS training_rows;

-- S3-2: include_for_modeling_flag distribution.
-- Expect a small pct flagged out vs base exclude_from_training_flag=0 rows.
SELECT
    exclude_from_training_flag,
    contract_price_change_outlier_flag,
    include_for_modeling_flag,
    COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- S3-3: Outlier flag rate by CUST_PROD_CATEGORY.
-- High outlier rates for non-GX categories warrant investigation.
-- GX sap_months<=3 bucket expected to have higher rate than others.
SELECT
    cust_prod_category,
    COUNT(*)                                                        AS total_rows,
    SUM(contract_price_change_outlier_flag)                         AS outlier_flagged,
    SUM(include_for_modeling_flag)                                  AS included_for_modeling,
    ROUND(SUM(contract_price_change_outlier_flag)
          / NULLIF(COUNT(*), 0) * 100, 2)                           AS outlier_pct
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
GROUP BY cust_prod_category
ORDER BY outlier_pct DESC;

-- S3-4: GX early-stage outlier behavior by sap_months.
-- Expect higher outlier rate at sap_months <= 3 vs > 3 for GX.
SELECT
    sap_months,
    COUNT(*)                                                AS total_rows,
    SUM(contract_price_change_outlier_flag)                 AS outlier_count,
    ROUND(SUM(contract_price_change_outlier_flag)
          / NULLIF(COUNT(*), 0) * 100, 2)                   AS outlier_pct
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
WHERE cust_prod_category = 'GX'
  AND prev_month_contract_price IS NOT NULL
GROUP BY sap_months
ORDER BY sap_months;

-- S3-5: Fix 9 validation — rows where next_valid_contract_price is non-NULL
-- despite the next raw row being excluded (zombie skipped correctly).
-- Review these rows to confirm outlier_flag is not firing on genuine reprices.
SELECT
    groupby_key,
    cal_month_start_dt,
    contract_price,
    prev_month_contract_price,
    next_valid_contract_price,
    contract_price_mom_pct_change,
    contract_price_change_outlier_flag,
    exclude_from_training_flag
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
WHERE ABS(contract_price_mom_pct_change) > 0.50
  AND next_valid_contract_price IS NOT NULL
  AND exclude_from_training_flag = 0
ORDER BY ABS(contract_price_mom_pct_change) DESC
LIMIT 100;

-- S3-6: Fix 11 — series_valid_month_count vs actual include_for_modeling_flag.
-- series_valid_month_count excludes only base exclude_from_training_flag rows;
-- include_for_modeling_flag also excludes contract_price_change_outlier_flag rows.
-- This query shows the gap. A large gap for a key warrants spot-check.
SELECT
    groupby_key,
    MAX(series_valid_month_count)                           AS series_valid_month_count,
    SUM(include_for_modeling_flag)                          AS actual_modeled_months,
    MAX(series_valid_month_count)
        - SUM(include_for_modeling_flag)                    AS outlier_excluded_months
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
GROUP BY groupby_key
HAVING MAX(series_valid_month_count) != SUM(include_for_modeling_flag)
ORDER BY outlier_excluded_months DESC
LIMIT 50;

-- S3-7: Spot-check known high-value genuine reprices are NOT flagged as outliers.
-- These drugs had large permanent price moves that must be retained for training.
SELECT
    groupby_key,
    brand_name,
    cal_month_start_dt,
    contract_price,
    prev_month_contract_price,
    contract_price_mom_pct_change,
    contract_price_change_outlier_flag,
    include_for_modeling_flag
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
WHERE brand_name IN ('ELIQUIS', 'XARELTO', 'ENBREL', 'JANUVIA', 'HUMIRA')
  AND ABS(contract_price_mom_pct_change) > 0.20
ORDER BY brand_name, cal_month_start_dt;


-- =============================================================
-- STEP 4 QA: contract_price_material_live_assumptions_v23
-- =============================================================

-- S4-1: One row per groupby_key (assumptions table is series-level).
-- Expected: 0 rows returned.
SELECT groupby_key, COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
GROUP BY groupby_key
HAVING COUNT(*) > 1
ORDER BY row_count DESC
LIMIT 20;

-- S4-2: acct_classification is fully populated — no NULLs or UNKNOWN.
-- Fix 14 validation. Expected: null_acct_class = 0, unknown_acct_class = 0.
SELECT
    COUNT(*)                                                        AS total_rows,
    SUM(CASE WHEN acct_classification IS NULL     THEN 1 ELSE 0 END) AS null_acct_class,
    SUM(CASE WHEN acct_classification = 'UNKNOWN' THEN 1 ELSE 0 END) AS unknown_acct_class
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23;

-- S4-3: trend_cap_applied distribution — confirm cap assignment maps to
-- correct segments (APOLLO/MPB Specialty/BX non-340B → ±15%;
-- DROP SHIP non-340B → ±10%; all others → ±2%).
SELECT
    trend_cap_applied,
    cust_prod_category,
    acct_classification,
    COUNT(DISTINCT groupby_key) AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
GROUP BY trend_cap_applied, cust_prod_category, acct_classification
ORDER BY trend_cap_applied, cust_prod_category, acct_classification;

-- S4-4: No fallback method (PF_AVG_YOY / MFR_AVG_YOY) used when
-- key has sufficient key-level YOY data (yoy_pairs_used >= 2).
-- Expected: bad_rows = 0.
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('PF_AVG_YOY', 'MFR_AVG_YOY')
  AND COALESCE(yoy_pairs_used, 0) >= 2;

-- S4-5: Step methods (STEP_UP_HISTORY / STEP_DOWN_HISTORY) should
-- only appear on APOLLO and BX. Expected: no other categories.
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key) AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('STEP_UP_HISTORY', 'STEP_DOWN_HISTORY')
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category;

-- S4-6: Trend method distribution by segment.
-- Review NO_TREND prevalence — very high pct may indicate eligibility
-- guard conditions (sign_only_eligible, wac_spread_ok) are too restrictive.
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key)                             AS key_count,
    ROUND(COUNT(DISTINCT groupby_key) * 100.0
          / SUM(COUNT(DISTINCT groupby_key)) OVER (PARTITION BY cust_prod_category), 2)
                                                            AS pct_of_category
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category, key_count DESC;

-- S4-7: expected_monthly_trend_pct is within cap boundaries.
-- No key should have |trend| > 0.15 for ±15% cap segments,
-- > 0.10 for ±10%, or > 0.02 for ±2%.
-- Expected: all bad_row counts = 0.
SELECT
    SUM(CASE WHEN trend_cap_applied = '±15%'
              AND ABS(expected_monthly_trend_pct) > 0.15001 THEN 1 ELSE 0 END) AS over_15pct_cap,
    SUM(CASE WHEN trend_cap_applied = '±10%'
              AND ABS(expected_monthly_trend_pct) > 0.10001 THEN 1 ELSE 0 END) AS over_10pct_cap,
    SUM(CASE WHEN trend_cap_applied = '±2%'
              AND ABS(expected_monthly_trend_pct) > 0.02001  THEN 1 ELSE 0 END) AS over_2pct_cap
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23;

-- S4-8: Cap boundary saturation — pct of keys hitting each cap level.
-- High saturation for ±15%/±10% segments confirms cap lift was warranted.
SELECT
    trend_cap_applied,
    cust_prod_category,
    COUNT(DISTINCT groupby_key)                                     AS key_count,
    SUM(CASE WHEN ABS(expected_monthly_trend_pct) >= 0.149 THEN 1 ELSE 0 END) AS at_15pct_cap,
    SUM(CASE WHEN ABS(expected_monthly_trend_pct) >= 0.099 THEN 1 ELSE 0 END) AS at_10pct_cap,
    SUM(CASE WHEN ABS(expected_monthly_trend_pct) >= 0.019 THEN 1 ELSE 0 END) AS at_2pct_cap,
    ROUND(AVG(expected_monthly_trend_pct) * 100, 3)                 AS avg_trend_pct
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
GROUP BY trend_cap_applied, cust_prod_category
ORDER BY trend_cap_applied, cust_prod_category;

-- S4-9: forecast_start_contract_price sanity — no zero or negative values.
-- Also confirm anchor cap (3x) is flagged correctly.
SELECT
    SUM(CASE WHEN forecast_start_contract_price IS NULL   THEN 1 ELSE 0 END) AS null_start_price,
    SUM(CASE WHEN forecast_start_contract_price <= 0      THEN 1 ELSE 0 END) AS zero_or_neg_price,
    SUM(CASE WHEN forecast_start_price_capped_flag = 1    THEN 1 ELSE 0 END) AS capped_series,
    COUNT(DISTINCT groupby_key)                                               AS total_series
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23;

-- S4-10: Fallback method coverage — pct of series using PF/MFR fallback.
-- Useful pipeline health metric. High fallback pct may indicate sparse data.
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key)                             AS key_count,
    ROUND(AVG(expected_monthly_trend_pct) * 100, 3)        AS avg_trend_pct,
    ROUND(AVG(avg_yoy_pct) * 100, 3)                       AS avg_raw_yoy_pct
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category, assigned_trend_method;


-- =============================================================
-- STEP 5 QA: backtest evaluation tables
-- (contract_price_bt_eval_detail_v23,
--  contract_price_bt_eval_summary_v23)
-- =============================================================

-- S5-1: No duplicate rows in eval detail at grain
-- (run_id + groupby_key + forecast_month).
-- Expected: 0 rows returned.
SELECT run_id, groupby_key, forecast_month, COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
GROUP BY run_id, groupby_key, forecast_month
HAVING COUNT(*) > 1
ORDER BY row_count DESC
LIMIT 20;

-- S5-2: Explosion flag audit — no series should explode (forecast > 2x start)
-- at high rates for cap-lifted segments whose caps are below 2x.
SELECT
    cust_prod_category,
    trend_cap_applied,
    COUNT_IF(forecast_explosion_flag = 1)   AS explosion_count,
    COUNT(*)                                AS total_rows,
    ROUND(COUNT_IF(forecast_explosion_flag = 1) * 100.0
          / NULLIF(COUNT(*), 0), 3)         AS explosion_rate_pct
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
GROUP BY cust_prod_category, trend_cap_applied
ORDER BY explosion_count DESC;

-- S5-3: review_priority distribution — flag high CRITICAL count as a
-- pipeline quality signal. CRITICAL = high-revenue + high APE.
SELECT
    review_priority,
    COUNT(*)                                AS row_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
GROUP BY review_priority
ORDER BY row_count DESC;

-- S5-4: WMAPE by cust_segment + acct_classification + trend_cap_applied.
-- Primary validation that cap-lifted segments outperform ±2% baseline.
SELECT
    run_id,
    cust_segment,
    acct_classification,
    trend_cap_applied,
    SUM(series_cnt)                                         AS series_cnt,
    ROUND(SUM(actual_dollars) / 1e6, 1)                     AS actual_dollars_mm,
    ROUND(SUM(wmape * actual_dollars)
          / NULLIF(SUM(actual_dollars), 0) * 100, 2)        AS weighted_wmape_pct,
    ROUND(SUM(error_dollars)
          / NULLIF(SUM(actual_dollars), 0) * 100, 2)        AS bias_pct,
    ROUND(SUM(pass_cnt_materiality)
          / NULLIF(SUM(series_cnt), 0) * 100, 1)            AS pass_rate_materiality_pct
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
GROUP BY run_id, cust_segment, acct_classification, trend_cap_applied
ORDER BY run_id, cust_segment, acct_classification, trend_cap_applied;

-- S5-5: WMAPE by cust_prod_category + trend_cap_applied.
-- Compare ±15% cap APOLLO/BX vs ±2% BX 340B to validate improvement.
SELECT
    run_id,
    cust_prod_category,
    trend_cap_applied,
    SUM(series_cnt)                                         AS series_cnt,
    ROUND(SUM(actual_dollars) / 1e6, 1)                     AS actual_dollars_mm,
    ROUND(SUM(wmape * actual_dollars)
          / NULLIF(SUM(actual_dollars), 0) * 100, 2)        AS weighted_wmape_pct,
    ROUND(SUM(error_dollars)
          / NULLIF(SUM(actual_dollars), 0) * 100, 2)        AS bias_pct,
    ROUND(SUM(pass_cnt_materiality)
          / NULLIF(SUM(series_cnt), 0) * 100, 1)            AS pass_rate_materiality_pct,
    SUM(explosion_cnt)                                      AS total_explosions
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
GROUP BY run_id, cust_prod_category, trend_cap_applied
ORDER BY run_id, cust_prod_category, trend_cap_applied;

-- S5-6: Top 50 highest-error series for manual review.
-- CRITICAL review_priority + highest APE = worst performers.
SELECT
    run_id,
    groupby_key,
    cust_prod_category,
    acct_classification,
    trend_cap_applied,
    assigned_trend_method,
    forecast_month,
    forecast_horizon_month_num,
    forecasted_contract_price,
    actual_contract_price,
    ROUND(ape_contract_price * 100, 2)      AS ape_pct,
    review_priority,
    revenue_quintile_desc,
    forecast_explosion_flag
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
WHERE review_priority = 'CRITICAL'
ORDER BY ae_dollars DESC
LIMIT 50;

-- S5-7: Eval summary row count matches expected distinct groups from detail.
-- Expected: counts should match (summary is a strict aggregation of detail).
SELECT
    (SELECT COUNT(*) FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23)
        AS summary_rows,
    (SELECT COUNT(DISTINCT CONCAT_WS('|', CAST(run_id AS STRING), forecast_month,
                                     cust_segment, acct_classification,
                                     cust_prod_category, trend_cap_applied))
     FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23)
        AS expected_summary_rows;


-- =============================================================
-- STEP 6 QA: live forecast tables
-- (contract_price_bt_future_actual_months_v23,
--  contract_price_bt_forecasted_v23)
-- =============================================================

-- S6-1: Horizon range in future_actual_months — should be 1 to 60.
-- Expected: min = 1, max = 60.
SELECT
    MIN(forecast_horizon_month_num) AS min_horizon,
    MAX(forecast_horizon_month_num) AS max_horizon,
    COUNT(DISTINCT forecast_month)  AS distinct_forecast_months,
    COUNT(DISTINCT groupby_key)     AS distinct_series
FROM uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23;

-- S6-2: No NULL forecasted_contract_price in bt_forecasted.
-- Expected: null_forecasts = 0.
SELECT
    COUNT(*)                                                        AS total_rows,
    SUM(CASE WHEN forecasted_contract_price IS NULL THEN 1 ELSE 0 END) AS null_forecasts,
    SUM(CASE WHEN forecasted_contract_price <= 0    THEN 1 ELSE 0 END) AS zero_or_neg_forecasts
FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23;

-- S6-3: Compounding sanity at horizon 12 — forecast at 1 year should be
-- approximately anchor * (1 + annual_trend). Annual trend = expected_monthly_trend_pct
-- for annual-compounding segments. Large deviations indicate compounding logic error.
SELECT
    cust_prod_category,
    acct_classification,
    ROUND(AVG(forecasted_contract_price / NULLIF(anchor_contract_price, 0)), 4)
        AS avg_1yr_forecast_to_anchor_ratio,
    ROUND(AVG(1 + expected_monthly_trend_pct), 4)
        AS expected_1yr_ratio,
    COUNT(DISTINCT groupby_key) AS series_count
FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23
WHERE forecast_horizon_month_num = 12
GROUP BY cust_prod_category, acct_classification
ORDER BY cust_prod_category, acct_classification;

-- S6-4: Fix G validation — WAC at jump_off vs max historical WAC.
-- Rows returned show drugs where point-in-time WAC differs meaningfully from
-- the prior MAX(WAC) approach. Large pct_diff confirms the fix changed outcomes.
SELECT
    f.groupby_key,
    f.jump_off_month,
    f.WAC                                                       AS jumpoff_wac,
    hist.max_wac,
    ROUND((hist.max_wac - f.WAC) / NULLIF(f.WAC, 0) * 100, 2)  AS pct_diff
FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23 f
JOIN (
    SELECT groupby_key, MAX(WAC_WEIGHTED) AS max_wac
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
    GROUP BY groupby_key
) hist ON f.groupby_key = hist.groupby_key
WHERE f.WAC IS NOT NULL
  AND ABS(hist.max_wac - f.WAC) / NULLIF(f.WAC, 0) > 0.05
ORDER BY pct_diff DESC
LIMIT 50;

-- S6-5: Forecast growth distribution at horizon 60 (5 years).
-- p95 5-year growth for ±15% segments should not exceed 1.15^5 ≈ 2.01x.
SELECT
    cust_prod_category,
    trend_cap_applied,
    COUNT(DISTINCT groupby_key)                                             AS series_cnt,
    ROUND(PERCENTILE(forecasted_contract_price
                     / NULLIF(anchor_contract_price, 0), 0.50), 3)         AS p50_5yr_growth,
    ROUND(PERCENTILE(forecasted_contract_price
                     / NULLIF(anchor_contract_price, 0), 0.90), 3)         AS p90_5yr_growth,
    ROUND(PERCENTILE(forecasted_contract_price
                     / NULLIF(anchor_contract_price, 0), 0.95), 3)         AS p95_5yr_growth,
    ROUND(MAX(forecasted_contract_price
              / NULLIF(anchor_contract_price, 0)), 3)                       AS max_5yr_growth
FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23
WHERE forecast_horizon_month_num = 60
GROUP BY cust_prod_category, trend_cap_applied
ORDER BY cust_prod_category, trend_cap_applied;

-- S6-6: Explosion flag by segment — confirm 3x threshold is not firing
-- spuriously on legitimately capped series.
SELECT
    cust_prod_category,
    trend_cap_applied,
    COUNT_IF(forecast_explosion_flag = 1)                       AS explosion_count,
    COUNT(*)                                                    AS total_rows,
    ROUND(AVG(forecasted_contract_price
              / NULLIF(anchor_contract_price, 0)), 3)           AS avg_forecast_to_anchor_ratio
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
GROUP BY cust_prod_category, trend_cap_applied
ORDER BY explosion_count DESC;

-- S6-7: Fix C2 validation — no fractional forecast_horizon_month_num values.
-- DATEDIFF(MONTH) should always return an integer.
-- Expected: fractional_horizons = 0.
SELECT
    SUM(CASE WHEN forecast_horizon_month_num != FLOOR(forecast_horizon_month_num)
             THEN 1 ELSE 0 END) AS fractional_horizons
FROM uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23;


-- =============================================================
-- STEP 7 QA: contract_price_forecast_output_monthly_v1
-- =============================================================

-- S7-1: Grain check — one row per groupby_key + FORECAST_CAL_YEAR_MONTH.
-- Expected: 0 rows returned.
SELECT groupby_key, FORECAST_CAL_YEAR_MONTH, COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1
GROUP BY groupby_key, FORECAST_CAL_YEAR_MONTH
HAVING COUNT(*) > 1
ORDER BY row_count DESC
LIMIT 20;

-- S7-2: No NULL or zero FORECASTED_CONTRACT_PRICE in output.
-- Expected: null_forecasts = 0, zero_forecasts = 0.
SELECT
    COUNT(*)                                                            AS total_rows,
    SUM(CASE WHEN FORECASTED_CONTRACT_PRICE IS NULL THEN 1 ELSE 0 END) AS null_forecasts,
    SUM(CASE WHEN FORECASTED_CONTRACT_PRICE <= 0    THEN 1 ELSE 0 END) AS zero_or_neg_forecasts,
    COUNT(DISTINCT groupby_key)                                         AS distinct_series
FROM uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1;

-- S7-3: LOAD_TS override check — confirm hardcoded timestamp is set
-- (not CURRENT_TIMESTAMP). All rows should show the same override value.
-- Expected: distinct_load_ts = 1 and load_ts = '2026-06-29T19:05:46.782+00:00'.
SELECT
    COUNT(DISTINCT LOAD_TS)     AS distinct_load_ts,
    MIN(LOAD_TS)                AS min_load_ts,
    MAX(LOAD_TS)                AS max_load_ts
FROM uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1;

-- S7-4: Required identifier fields have no NULLs.
SELECT
    SUM(CASE WHEN groupby_key        IS NULL THEN 1 ELSE 0 END) AS null_groupby_key,
    SUM(CASE WHEN MTRL_NUM           IS NULL THEN 1 ELSE 0 END) AS null_mtrl_num,
    SUM(CASE WHEN SAP_CUST_NUM       IS NULL THEN 1 ELSE 0 END) AS null_sap_cust_num,
    SUM(CASE WHEN CUST_SEGMENT       IS NULL THEN 1 ELSE 0 END) AS null_cust_segment,
    SUM(CASE WHEN ACCT_CLASSIFICATION IS NULL THEN 1 ELSE 0 END) AS null_acct_class,
    SUM(CASE WHEN FCST_ORIGIN_YEAR_MONTH IS NULL THEN 1 ELSE 0 END) AS null_fcst_origin
FROM uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1;

-- S7-5: WAC_PRICE_DECREASE_FLAG is 0 or 1 only (no NULLs — COALESCE applied).
-- Expected: null_flag = 0, invalid_flag = 0.
SELECT
    SUM(CASE WHEN WAC_PRICE_DECREASE_FLAG IS NULL          THEN 1 ELSE 0 END) AS null_flag,
    SUM(CASE WHEN WAC_PRICE_DECREASE_FLAG NOT IN (0, 1)    THEN 1 ELSE 0 END) AS invalid_flag,
    SUM(WAC_PRICE_DECREASE_FLAG)                                               AS flagged_rows
FROM uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1;

-- S7-6: Forecast horizon coverage — confirm all expected FORECAST_YEAR_NUM
-- values are present (1–5 if 60-month horizon).
SELECT
    FORECAST_YEAR_NUM,
    COUNT(DISTINCT groupby_key) AS distinct_series,
    COUNT(*)                    AS total_rows
FROM uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1
GROUP BY FORECAST_YEAR_NUM
ORDER BY FORECAST_YEAR_NUM;

-- S7-7: SLS_CTGRY_PRC_PROD_GRP distribution in output — should match
-- CUST_PROD_CATEGORY distribution from base table.
SELECT
    SLS_CTGRY_PRC_PROD_GRP,
    COUNT(DISTINCT groupby_key) AS distinct_series,
    COUNT(*)                    AS total_rows
FROM uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1
GROUP BY SLS_CTGRY_PRC_PROD_GRP
ORDER BY total_rows DESC;


-- =============================================================
-- PIPELINE HEALTH SUMMARY
-- Run last — aggregates key metrics across all steps in one view.
-- =============================================================

SELECT
    'S1: base_table'                                    AS step,
    CONCAT(CAST(COUNT(*) AS STRING), ' rows')           AS row_metric,
    CONCAT(CAST(COUNT(DISTINCT groupby_key) AS STRING), ' series') AS series_metric,
    CONCAT(CAST(SUM(CASE WHEN exclude_from_training_flag = 1 THEN 1 ELSE 0 END)
                * 100 / NULLIF(COUNT(*), 0) AS STRING), '% excluded from training') AS quality_metric
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23

UNION ALL

SELECT
    'S2: history_profile',
    CONCAT(CAST(COUNT(*) AS STRING), ' series'),
    CONCAT(CAST(SUM(CASE WHEN has_min_24m_history_flag = 1 THEN 1 ELSE 0 END) AS STRING),
           ' have 24m+ history'),
    CONCAT(CAST(SUM(CASE WHEN top_100_brand_flag = 1 THEN 1 ELSE 0 END) AS STRING),
           ' top-100-brand series')
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23

UNION ALL

SELECT
    'S3: training_clean',
    CONCAT(CAST(COUNT(*) AS STRING), ' rows'),
    CONCAT(CAST(SUM(include_for_modeling_flag) AS STRING), ' modeled rows'),
    CONCAT(CAST(ROUND(SUM(contract_price_change_outlier_flag) * 100.0
                      / NULLIF(COUNT(*), 0), 2) AS STRING), '% outlier-flagged')
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23

UNION ALL

SELECT
    'S4: live_assumptions',
    CONCAT(CAST(COUNT(*) AS STRING), ' series'),
    CONCAT(CAST(SUM(CASE WHEN assigned_trend_method = 'NO_TREND' THEN 1 ELSE 0 END)
                * 100 / NULLIF(COUNT(*), 0) AS STRING), '% NO_TREND'),
    CONCAT(CAST(SUM(CASE WHEN assigned_trend_method IN ('PF_AVG_YOY','MFR_AVG_YOY')
                         THEN 1 ELSE 0 END) AS STRING), ' fallback series')
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23

UNION ALL

SELECT
    'S6: bt_forecasted',
    CONCAT(CAST(COUNT(*) AS STRING), ' rows'),
    CONCAT(CAST(COUNT(DISTINCT groupby_key) AS STRING), ' series'),
    CONCAT(CAST(SUM(CASE WHEN forecast_explosion_flag = 1 THEN 1 ELSE 0 END) AS STRING),
           ' explosions')
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23

UNION ALL

SELECT
    'S7: forecast_output',
    CONCAT(CAST(COUNT(*) AS STRING), ' rows'),
    CONCAT(CAST(COUNT(DISTINCT groupby_key) AS STRING), ' series'),
    CONCAT(CAST(SUM(CASE WHEN FORECASTED_CONTRACT_PRICE IS NULL THEN 1 ELSE 0 END) AS STRING),
           ' null forecasts')
FROM uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1
;
