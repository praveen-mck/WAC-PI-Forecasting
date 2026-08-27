-- =====================================================================
-- PERF 1: OPTIMIZE Step 6 output before Step 8 runs.
--         Z-ordering on run_id + groupby_key aligns file layout with
--         Step 8's join predicate, enabling file pruning on serverless
--         instead of full 17B row scans. Run this between Step 6 and
--         Step 8 every pipeline execution.
-- PERF 2: WAC lookup pre-materialized as contract_price_bt_wac_jumpoff_v23
--         before Step 8. Avoids aggregating all of modeling_base inline
--         across 17B rows. Build once per pipeline run, then join the
--         pre-built table in Step 8.
-- PERF 3: Validation queries (Q_7_1, Q_7_2, Q_7_3) moved outside the
--         pipeline. On serverless they compete for warehouse compute and
--         Q_7_2 alone reads 238GB. Run ad-hoc after confirmed-clean runs
--         only. Q_7_3 (distinct month count) is the only lightweight check
--         worth keeping inline — retained at end of Step 6 block.
-- =====================================================================


-- =====================================================================
-- STEP 6: FUTURE ACTUAL MONTHS
-- Fix A: modeling base join pre-aggregated to DISTINCT
--        groupby_key + cal_month_start_dt before joining.
-- Fix C2: months_between → DATEDIFF(MONTH) for forecast_horizon_month_num.
--         This value feeds the Step 8 compounding exponent directly.
--         months_between can return fractional values that truncate
--         incorrectly (e.g. 11.97 → 11 instead of 12), causing the
--         wrong number of compounding steps to fire at horizon boundaries.
-- Fix E: calendar spine now generated synthetically via SEQUENCE(0,59)
--        instead of joining to modeling_base for dates. modeling_base
--        only contains actuals (through 2026-08); relying on it capped
--        the forecast at the last actual month rather than 60 months
--        forward from jump_off_month.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.groupby_key,
    ra.sap_cust_num_trim,
    ra.mtrl_num,
    ADD_MONTHS(ra.jump_off_month, pos.n)                         AS forecast_month,
    pos.n + 1                                                    AS forecast_horizon_month_num,
    DATE_FORMAT(ADD_MONTHS(ra.jump_off_month, pos.n), 'yyyy-MM') AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v23 ra
CROSS JOIN (
    SELECT EXPLODE(SEQUENCE(0, 59)) AS n
) pos
;


-- PERF 1: OPTIMIZE Step 6 output before Step 8.
-- Z-order on join keys enables file pruning on serverless warehouse.
OPTIMIZE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23
ZORDER BY (run_id, groupby_key);


-- Q_7_3: Lightweight inline check — confirm each run_id has exactly
-- 60 distinct forecast months. Safe to keep in pipeline (no full scan).
SELECT
    run_id,
    COUNT(DISTINCT forecast_month)  AS distinct_months,
    MIN(forecast_month)             AS first_month,
    MAX(forecast_month)             AS last_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23
GROUP BY run_id
ORDER BY run_id;


-- =====================================================================
-- PERF 2: PRE-MATERIALIZE WAC LOOKUP TABLE
-- Build once before Step 8. Replaces the inline subquery that
-- aggregated all of modeling_base across every row of the 17B row
-- Step 8 join. Z-ordered on join keys for file pruning on serverless.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_wac_jumpoff_v23 AS
SELECT
    groupby_key,
    cal_month_start_dt,
    MAX(WAC_WEIGHTED)      AS WAC,
    MAX(TOTAL_NET_REVENUE) AS total_net_revenue
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
GROUP BY groupby_key, cal_month_start_dt;

OPTIMIZE uspd_analytics_den.analytics_gold.contract_price_bt_wac_jumpoff_v23
ZORDER BY (groupby_key, cal_month_start_dt);


-- =====================================================================
-- STEP 8: FORECASTED
-- Fix D: ROUND(horizon/3.0, 0) replaces CEIL(horizon/3.0) in 340B
--        compounding formula to remove systematic upward bias.
-- Fix G: WAC src join replaced with jump_off-month WAC instead of
--        MAX(WAC) across all history. MAX() picked the highest WAC
--        ever seen, inflating implied_forecast_wac_spread in eval
--        detail for drugs with mid-history WAC increases. The join
--        now targets the specific modeling_base row at jump_off_month
--        per groupby_key for an accurate point-in-time WAC reference.
--        WAC lookup now sourced from pre-materialized
--        contract_price_bt_wac_jumpoff_v23 (see PERF 2 above).
--
-- Note: no compounding cap applied — price compounds through the full
--       60-month forecast horizon for all branches.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23 AS
SELECT
    ra.run_id,
    ra.jump_off_month,
    ra.history_start_dt,
    ra.history_end_dt,
    ra.groupby_key,
    ra.sap_cust_num_trim,
    ra.mtrl_num,
    ra.cust_segment,
    ra.acct_classification,
    ra.cust_prod_category,
    ra.national_grp_id,
    ra.national_grp_desc,
    ra.common_grp_id,
    ra.common_grp_desc,
    ra.subset_l2_id_resolved,
    ra.mtrl_nme_nvgton,
    ra.ndc_num,
    ra.product_family,
    ra.therapeutic_class,
    ra.manufacturer_id,
    ra.manufacturer_name,
    ra.final_product_group,
    ra.final_product_group_level,
    src.WAC,
    src.total_net_revenue,
    ra.top_100_brand_flag,
    ra.brand_wac_rank,
    ra.first_month,
    ra.anchor_month,
    ra.months_since_first_asof_jumpoff,
    ra.anchor_contract_price,
    ra.anchor_wac_weighted,
    ra.anchor_wac_spread,
    ra.forecast_start_contract_price,
    ra.forecast_start_wac_spread,
    ra.forecast_start_price_source,
    ra.forecast_start_price_capped_flag,
    ra.sparse_price_confidence,
    ra.is_sparse_price_flag,
    ra.recent_6m_months,
    ra.latest_6_observed_months,
    ra.resolved_monthly_trend_pct,
    ra.trend_source,
    ra.trend_cap_applied,
    ra.typical_increase_month,
    fam.forecast_month,
    fam.forecast_horizon_month_num,
    fam.forecast_year_month,
    CASE
        WHEN ra.forecast_start_contract_price IS NULL THEN NULL
        -- 340B-CP / 340B-CE quarterly compounding — excludes annual-rate categories.
        -- 340B contract prices move with rebate cycles adjusting multiple times/year.
        -- Fix D: ROUND(horizon/3.0, 0) replaces CEIL(horizon/3.0) to remove bias.
        -- No cap: compounding runs through full 60-month forecast horizon.
        --
        -- APOLLO and MPB Specialty excluded: their trend rates are ANNUAL
        -- (avg_yoy_pct, pf_avg_yoy_pct, avg_step_up/down_pct — all YOY rates).
        -- Routing 340B-CP|APOLLO or 340B-CP|MPB Specialty to quarterly compounding
        -- applies an annual rate 8x instead of 2x: 1.15^8=3.06x vs 1.15^2=1.32x.
        -- These categories fall through to the annual compounding branch below.
        --
        -- Categories correctly using quarterly compounding:
        --   GLP-1       — raw_regression_trend_pct is quarterly OLS slope
        --   MPB Plasma  — raw_regression_trend_pct is quarterly OLS slope
        --   BX 340B     — regression trend (quarterly OLS slope)
        --   GX 340B     — regression trend (quarterly OLS slope)
        --   Other 340B  — regression trend (quarterly OLS slope)
        WHEN ra.acct_classification IN ('340B-CP', '340B-CE')
         AND ra.cust_prod_category NOT IN ('APOLLO', 'MPB Specialty')
        THEN GREATEST(
            ra.forecast_start_contract_price * POWER(
                1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                ROUND(fam.forecast_horizon_month_num / 3.0, 0)
            ), 0)
        -- All other categories: annual compounding with typical_increase_month
        -- offset. FLOOR ensures clean annual steps. The offset shifts the
        -- compounding so the step fires at the correct calendar month.
        -- typical_increase_month is populated for: APOLLO, BX, GLP-1,
        -- MPB Specialty, MPB Plasma.
        -- NULL for GX, OTC, BIOSIMS, DROP SHIP, VAX → offset=0 (step at month 12).
        -- No cap: compounding runs through full 60-month forecast horizon.
        -- Offset formula by branch:
        --   typical > jump_off_month : 12 - (typical - jump_off)
        --     → months to pad so FLOOR fires at next occurrence
        --   typical = jump_off_month : 0
        --     → increase fires exactly at month 12
        --   typical < jump_off_month : 12 - (12 - jump_off + typical)
        --     = jump_off - typical (months since last increase)
        --     → pad so FLOOR fires at correct forward horizon
        ELSE GREATEST(
            ra.forecast_start_contract_price * POWER(
                1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                FLOOR(
                    (fam.forecast_horizon_month_num
                     + CASE
                         WHEN ra.typical_increase_month IS NULL
                         THEN 0
                         WHEN ra.typical_increase_month > MONTH(ra.jump_off_month)
                         THEN 12 - (ra.typical_increase_month - MONTH(ra.jump_off_month))
                         WHEN ra.typical_increase_month = MONTH(ra.jump_off_month)
                         THEN 0
                         ELSE 12 - (12 - MONTH(ra.jump_off_month) + ra.typical_increase_month)
                       END
                    ) / 12.0
                )
            ), 0)
    END                                                         AS forecasted_contract_price
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v23 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23 fam
  ON ra.run_id = fam.run_id AND ra.groupby_key = fam.groupby_key
-- PERF 2: join pre-materialized WAC lookup instead of inline subquery.
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_wac_jumpoff_v23 src
  ON  ra.groupby_key       = src.groupby_key
 AND  src.cal_month_start_dt = ra.jump_off_month
;


-- =====================================================================
-- AD-HOC VALIDATION QUERIES (PERF 3: removed from pipeline)
-- Run manually after pipeline completion to verify output correctness.

-- =====================================================================

-- Q_7_1: Confirm forecast_horizon_month_num is always a positive integer
-- and starts at 1 for jump_off_month rows.
-- SELECT COUNT(*) AS bad_rows
-- FROM uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23
-- WHERE forecast_horizon_month_num < 1
--    OR forecast_horizon_month_num != CAST(forecast_horizon_month_num AS INT);

-- Q_7_2: Confirm no duplicate run_id + groupby_key + forecast_month rows.
-- SELECT run_id, groupby_key, forecast_month, COUNT(*) AS row_count
-- FROM uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23
-- GROUP BY run_id, groupby_key, forecast_month
-- HAVING COUNT(*) > 1
-- ORDER BY row_count DESC
-- LIMIT 20;

-- Q_8_1: Confirm Fix G — WAC at jump_off vs MAX(WAC) difference.
-- Shows keys where the prior MAX(WAC) approach would have differed
-- from the point-in-time jump_off WAC. Large values indicate drugs
-- with meaningful WAC increases mid-history.
-- SELECT
--     f.groupby_key,
--     f.jump_off_month,
--     f.WAC                                                   AS jumpoff_wac,
--     hist.max_wac,
--     ROUND((hist.max_wac - f.WAC) / NULLIF(f.WAC, 0) * 100, 2) AS pct_diff
-- FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23 f
-- JOIN (
--     SELECT groupby_key, MAX(WAC_WEIGHTED) AS max_wac
--     FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
--     GROUP BY groupby_key
-- ) hist ON f.groupby_key = hist.groupby_key
-- WHERE f.WAC IS NOT NULL
--   AND ABS(hist.max_wac - f.WAC) / NULLIF(f.WAC, 0) > 0.05
-- ORDER BY pct_diff DESC
-- LIMIT 50;

-- Q_8_2: Confirm no forecast_explosion_flag = 1 rows for cap-lifted segments
-- at plausible magnitudes (sanity check that 3x threshold is not firing
-- on legitimate ±15% compounded forecasts).
-- SELECT
--     cust_prod_category,
--     trend_cap_applied,
--     COUNT_IF(forecast_explosion_flag = 1) AS explosion_count,
--     COUNT(*) AS total_rows,
--     ROUND(AVG(forecasted_contract_price / NULLIF(anchor_contract_price, 0)), 3)
--         AS avg_forecast_to_anchor_ratio
-- FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
-- GROUP BY cust_prod_category, trend_cap_applied
-- ORDER BY explosion_count DESC;

-- Q_EVAL_1: Summary pass rates by trend_cap_applied.
-- Primary validation that cap-lifted segments improve vs ±2% baseline.
-- SELECT
--     run_id,
--     cust_prod_category,
--     trend_cap_applied,
--     SUM(series_cnt)                                         AS series_cnt,
--     ROUND(SUM(actual_dollars) / 1e6, 1)                     AS actual_dollars_mm,
--     ROUND(SUM(error_dollars) / NULLIF(SUM(actual_dollars), 0) * 100, 2)
--                                                             AS bias_pct,
--     ROUND(SUM(wmape * actual_dollars) / NULLIF(SUM(actual_dollars), 0) * 100, 2)
--                                                             AS weighted_wmape_pct,
--     ROUND(SUM(pass_cnt_materiality) / NULLIF(SUM(series_cnt), 0) * 100, 1)
--                                                             AS pass_rate_materiality_pct
-- FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
-- GROUP BY run_id, cust_prod_category, trend_cap_applied
-- ORDER BY run_id, cust_prod_category, trend_cap_applied;

-- Q_EVAL_2: Explosion flag count by segment — confirm 3x threshold
-- is not firing spuriously on cap-lifted keys.
-- SELECT
--     cust_prod_category,
--     trend_cap_applied,
--     SUM(explosion_cnt)                                      AS total_explosions,
--     SUM(series_cnt)                                         AS total_series,
--     ROUND(SUM(explosion_cnt) / NULLIF(SUM(series_cnt), 0) * 100, 3)
--                                                             AS explosion_rate_pct
-- FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
-- GROUP BY cust_prod_category, trend_cap_applied
-- ORDER BY total_explosions DESC;