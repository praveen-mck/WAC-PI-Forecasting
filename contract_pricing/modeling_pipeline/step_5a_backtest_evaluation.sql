/* =====================================================================
   CONTRACT PRICE BACKTEST PIPELINE v23 — STEPS 5b ONWARD
   ---------------------------------------------------------------------
   Prerequisites: Steps 1–4 must be run first.
     Step 1  — contract_price_bt_series_profile_v23
     Step 2  — contract_price_bt_run_eligibility_v23
     Step 3  — contract_price_bt_last_actual_v23
     Step 4  — contract_price_bt_latest_obs_v23
     Step 4  — contract_price_bt_material_assumptions_v23  ← authoritative
                assumption logic lives here; do NOT recompute in this file.

   Step 5a is intentionally absent from this file.
   contract_price_bt_material_assumptions_v23 is written by the
   standalone step 4 script and consumed here via a direct join in
   step 5b. Duplicating the assumption logic in this file caused v23
   logic to silently override the correct v28 step 4 output, producing
   identical results across all pipeline versions.

   This file runs:
     Step 5b — contract_price_bt_resolved_assumptions_v23
     Step 7  — contract_price_bt_future_actual_months_v23
     Step 8  — contract_price_bt_forecasted_v23
     Eval    — contract_price_bt_eval_detail_v23
     Eval    — contract_price_bt_eval_summary_v23

   Fixes applied vs prior version:
     Fix A  — Step 7: modeling_base pre-aggregated to DISTINCT
               groupby_key + cal_month_start_dt before joining.
     Fix B  — Eval detail: actuals LEFT JOIN pre-aggregated to
               groupby_key + cal_month_start_dt before joining.
     Fix C1 — Step 5b: months_between → DATEDIFF(MONTH) for
               months_since_first_asof_jumpoff.
     Fix C2 — Step 7: months_between → DATEDIFF(MONTH) for
               forecast_horizon_month_num. This feeds the Step 8
               compounding exponent directly — incorrect truncation
               would cause the wrong number of compounding steps.
     Fix D  — Step 8: ROUND(horizon/3.0,0) replaces CEIL(horizon/3.0)
               to remove systematic upward bias in 340B compounding.
     Fix E  — REVERTED. e.acct_classification from the eligibility
               table is the correct point-in-time value. ma.acct_classification
               from Step 4 pf_lookup uses MAX() over all modeling_base history
               and returns UNKNOWN for keys where acct_classification is NULL
               in modeling_base (~1.06M rows). e.acct_classification is always
               populated and reflects the current classification at forecast time.
     Fix F  — Step 5b: ma.trend_cap_applied added to SELECT so
               cap-lifted segment QA is available in eval tables.
     Fix G  — Step 8: WAC src join replaced with jump_off-month WAC
               instead of MAX(WAC) across all history. MAX() picked
               the highest WAC ever recorded, inflating implied_
               forecast_wac_spread in eval detail for drugs with
               mid-history WAC increases.
   ===================================================================== */


-- =====================================================================
-- STEP 5b: RESOLVED ASSUMPTIONS
-- Joins directly to step 4 output (contract_price_bt_material_assumptions_v23).
-- No assumption logic here — step 4 is the single source of truth.
--
-- Fix C1: months_between → DATEDIFF(MONTH) for months_since_first_asof_jumpoff.
-- Fix E (reverted): e.acct_classification retained as primary source.
--   ma.acct_classification returns UNKNOWN for ~1M keys where acct_classification
--   is NULL in modeling_base; eligibility table always has the correct value.
-- Fix F:  ma.trend_cap_applied added to SELECT.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v23 AS
SELECT
    e.run_id,
    e.jump_off_month,
    e.history_start_dt,
    e.history_end_dt,
    e.groupby_key,
    e.sap_cust_num_trim,
    e.mtrl_num,
    e.cust_segment,
    -- Fix E reverted: e.acct_classification is the correct point-in-time value.
    -- ma.acct_classification returns UNKNOWN for keys where acct_classification
    -- is NULL in modeling_base (pf_lookup MAX() returns UNKNOWN fallback).
    -- Eligibility table always carries the current classification correctly.
    e.acct_classification                                       AS acct_classification,
    e.cust_prod_category,
    e.national_grp_id,
    e.national_grp_desc,
    e.common_grp_id,
    e.common_grp_desc,
    e.subset_l2_id_resolved,
    e.mtrl_nme_nvgton,
    e.ndc_num,
    e.product_family,
    e.therapeutic_class,
    e.manufacturer_id,
    e.manufacturer_name,
    e.final_product_group,
    e.final_product_group_level,
    e.WAC,
    e.Total_Net_Revenue,
    e.top_100_brand_flag,
    e.brand_wac_rank,
    e.first_month,
    la.anchor_month,
    -- Fix C1: DATEDIFF(MONTH) replaces months_between() for semantic
    -- correctness. months_between returns fractional months based on
    -- exact day differences; DATEDIFF(MONTH) returns calendar months.
    -- Results are identical when both dates are the 1st of the month
    -- (as they always are here), but DATEDIFF is the correct function.
    DATEDIFF(MONTH, e.first_month, e.jump_off_month)           AS months_since_first_asof_jumpoff,
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
    ma.expected_monthly_trend_pct   AS resolved_monthly_trend_pct,
    ma.assigned_trend_method        AS trend_source,
    -- Fix F: trend_cap_applied passed through for cap-lifted segment QA
    -- in eval detail and eval summary. Populated by step 4 Fix 15.
    ma.trend_cap_applied,
    ma.typical_increase_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v23 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23 la
  ON e.run_id = la.run_id AND e.groupby_key = la.groupby_key
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23 ma
  ON e.run_id = ma.run_id AND e.groupby_key = ma.groupby_key
WHERE e.is_eligible_for_run = 1
  AND la.anchor_contract_price IS NOT NULL
;


-- =====================================================================
-- STEP 7: FUTURE ACTUAL MONTHS
-- Fix A: modeling base join pre-aggregated to DISTINCT
--        groupby_key + cal_month_start_dt before joining.
-- Fix C2: months_between → DATEDIFF(MONTH) for forecast_horizon_month_num.
--         This value feeds the Step 8 compounding exponent directly.
--         months_between can return fractional values that truncate
--         incorrectly (e.g. 11.97 → 11 instead of 12), causing the
--         wrong number of compounding steps to fire at horizon boundaries.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.groupby_key,
    ra.sap_cust_num_trim,
    ra.mtrl_num,
    b.cal_month_start_dt                                        AS forecast_month,
    -- Fix C2: DATEDIFF(MONTH) replaces months_between() here.
    -- forecast_horizon_month_num feeds FLOOR(horizon/12.0) and
    -- FLOOR(horizon/3.0) in Step 8 — fractional truncation errors
    -- would fire the wrong compounding step count at year/quarter
    -- boundaries. DATEDIFF(MONTH) always returns an integer.
    DATEDIFF(MONTH, ra.jump_off_month, b.cal_month_start_dt) + 1
                                                                AS forecast_horizon_month_num,
    DATE_FORMAT(b.cal_month_start_dt, 'yyyy-MM')                AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v23 ra
JOIN (
    SELECT DISTINCT groupby_key, cal_month_start_dt
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
) b
  ON ra.groupby_key       = b.groupby_key
 AND b.cal_month_start_dt >= ra.jump_off_month
 AND b.cal_month_start_dt <  ADD_MONTHS(ra.jump_off_month, 60)
;


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
--
-- Note: the 340B quarterly cap (8 quarters = 24 months) and annual
-- cap (2 years = 24 months) are symmetrically equivalent by design.
-- Both bound maximum compounding to a 2-year horizon.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23 AS  -- Fixed: added missing _v23 suffix
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
        -- Cap: 8 quarters = 24 months max, symmetric with annual cap of 2 years.
        -- Fix D: ROUND(horizon/3.0, 0) replaces CEIL(horizon/3.0) to remove bias.
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
                LEAST(ROUND(fam.forecast_horizon_month_num / 3.0, 0), 8)
            ), 0)
        -- All other categories: annual compounding with typical_increase_month
        -- offset. FLOOR ensures clean annual steps. The offset shifts the
        -- compounding so the step fires at the correct calendar month.
        -- typical_increase_month is populated for: APOLLO, BX, GLP-1,
        -- MPB Specialty, MPB Plasma.
        -- NULL for GX, OTC, BIOSIMS, DROP SHIP, VAX → offset=0 (step at month 12).
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
                LEAST(
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
                    ), 2)
            ), 0)
    END                                                         AS forecasted_contract_price
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v23 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23 fam
  ON ra.run_id = fam.run_id AND ra.groupby_key = fam.groupby_key
-- Fix G: point-in-time WAC at jump_off_month replaces MAX(WAC) across
-- all history. MAX() inflated WAC for drugs with mid-history increases,
-- distorting implied_forecast_wac_spread in eval detail.
-- Aggregated to groupby_key + jump_off_month to handle the rare case
-- where multiple rows share the same key and month (defensive).
LEFT JOIN (
    SELECT
        groupby_key,
        cal_month_start_dt,
        MAX(WAC_WEIGHTED)       AS WAC,
        MAX(TOTAL_NET_REVENUE)  AS total_net_revenue
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
    GROUP BY groupby_key, cal_month_start_dt
) src
  ON  ra.groupby_key   = src.groupby_key
 AND  src.cal_month_start_dt = ra.jump_off_month
;


-- =====================================================================
-- EVAL DETAIL
-- Fix B: actuals LEFT JOIN pre-aggregated to groupby_key +
--        cal_month_start_dt before joining.
-- trend_cap_applied passed through from forecasted for QA.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23 AS
WITH joined AS (
    SELECT
        f.run_id,
        f.jump_off_month,
        f.groupby_key,
        f.sap_cust_num_trim,
        f.mtrl_num,
        f.forecast_month,
        f.forecast_horizon_month_num,
        f.forecast_year_month,
        f.sparse_price_confidence,
        f.is_sparse_price_flag,
        f.cust_segment,
        f.acct_classification,
        f.cust_prod_category,
        f.national_grp_id,
        f.national_grp_desc,
        f.common_grp_id,
        f.common_grp_desc,
        f.subset_l2_id_resolved,
        f.mtrl_nme_nvgton,
        f.ndc_num,
        f.product_family,
        f.therapeutic_class,
        f.manufacturer_id,
        f.manufacturer_name,
        f.final_product_group,
        f.final_product_group_level,
        f.WAC,
        f.total_net_revenue,
        f.top_100_brand_flag,
        f.brand_wac_rank,
        f.first_month,
        f.anchor_month,
        f.months_since_first_asof_jumpoff,
        f.anchor_contract_price,
        f.anchor_wac_weighted,
        f.anchor_wac_spread,
        f.forecast_start_contract_price,
        f.forecast_start_price_source,
        f.forecast_start_price_capped_flag,
        f.resolved_monthly_trend_pct,
        f.trend_source,
        f.trend_cap_applied,
        f.forecasted_contract_price,
        f.typical_increase_month,
        f.recent_6m_months,
        f.latest_6_observed_months,
        a.brand_name,
        a.contract_price                                        AS actual_contract_price,
        a.account_class_cd,
        a.wac_weighted                                          AS actual_wac_weighted,
        a.wac_spread                                            AS actual_wac_spread,
        a.total_sls_qty                                         AS actual_sls_qty,
        a.total_net_cos                                         AS actual_net_cos,
        COALESCE(a.wac_mom_decrease_flag,          0)           AS wac_price_decrease_flag,
        COALESCE(a.wac_5pct_drop_flag,             0)           AS wac_significant_decrease_flag,
        COALESCE(a.contract_price_drop_30pct_flag, 0)           AS contract_price_drop_30pct_flag,
        COALESCE(a.contract_price_inc_30pct_flag,  0)           AS contract_price_inc_30pct_flag
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23 f
    LEFT JOIN (
        -- Fix B: pre-aggregate actuals to groupby_key + cal_month_start_dt
        -- before joining to prevent fan-out from multiple modeling_base rows
        -- per series-month reaching this join.
        SELECT
            groupby_key,
            cal_month_start_dt,
            MAX(brand_name)                                     AS brand_name,
            MAX(account_class_cd)                               AS account_class_cd,
            MAX(wac_weighted)                                   AS wac_weighted,
            MAX(wac_spread)                                     AS wac_spread,
            MAX(wac_mom_decrease_flag)                          AS wac_mom_decrease_flag,
            MAX(wac_5pct_drop_flag)                             AS wac_5pct_drop_flag,
            MAX(contract_price_drop_30pct_flag)                 AS contract_price_drop_30pct_flag,
            MAX(contract_price_inc_30pct_flag)                  AS contract_price_inc_30pct_flag,
            SUM(total_net_cos) / NULLIF(SUM(total_sls_qty), 0)  AS contract_price,
            SUM(total_sls_qty)                                  AS total_sls_qty,
            SUM(total_net_cos)                                  AS total_net_cos
        FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
        WHERE exclude_from_actuals_flag = 0
        GROUP BY groupby_key, cal_month_start_dt
    ) a
      ON f.groupby_key    = a.groupby_key
     AND f.forecast_month = a.cal_month_start_dt
    WHERE f.forecast_month IS NOT NULL
),

calc AS (
    SELECT
        j.*,
        j.forecasted_contract_price * j.actual_sls_qty          AS forecasted_dollars,
        j.actual_contract_price     * j.actual_sls_qty          AS actual_dollars,
        j.forecasted_contract_price - j.actual_contract_price   AS error_contract_price,
        ABS(j.forecasted_contract_price - j.actual_contract_price)
                                                                AS ae_contract_price,
        CASE WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
            THEN (j.forecasted_contract_price - j.actual_contract_price)
                 / j.actual_contract_price
        END                                                     AS bias_contract_price,
        CASE WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
            THEN ABS(j.forecasted_contract_price - j.actual_contract_price)
                 / ABS(j.actual_contract_price)
        END                                                     AS ape_contract_price,
        (j.forecasted_contract_price - j.actual_contract_price)
            * j.actual_sls_qty                                  AS error_dollars,
        ABS(j.forecasted_contract_price - j.actual_contract_price)
            * j.actual_sls_qty                                  AS ae_dollars,
        CASE WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
              AND j.actual_sls_qty IS NOT NULL AND j.actual_sls_qty <> 0
            THEN (j.forecasted_contract_price - j.actual_contract_price)
                 / j.actual_contract_price
        END                                                     AS bias_dollars,
        CASE WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
              AND j.actual_sls_qty IS NOT NULL AND j.actual_sls_qty <> 0
            THEN ABS(j.forecasted_contract_price - j.actual_contract_price)
                 / ABS(j.actual_contract_price)
        END                                                     AS ape_dollars,
        CASE WHEN j.actual_wac_weighted IS NOT NULL AND j.actual_wac_weighted <> 0
            THEN (j.forecasted_contract_price / j.actual_wac_weighted) - 1
        END                                                     AS implied_forecast_wac_spread
    FROM joined j
),

run_totals AS (
    SELECT
        run_id,
        SUM(ABS(error_dollars))  AS total_abs_error_dollars,
        SUM(ABS(actual_dollars)) AS total_abs_actual_dollars
    FROM calc
    GROUP BY run_id
),

series_dollars AS (
    SELECT
        run_id,
        groupby_key,
        SUM(ABS(actual_dollars)) AS series_total_actual_dollars
    FROM calc
    GROUP BY run_id, groupby_key
),

series_ranked AS (
    SELECT
        run_id,
        groupby_key,
        series_total_actual_dollars,
        NTILE(5) OVER (
            PARTITION BY run_id
            ORDER BY series_total_actual_dollars DESC NULLS LAST
        )                                                       AS revenue_quintile_desc
    FROM series_dollars
)

SELECT
    c.*,
    CASE
        WHEN c.ape_dollars IS NULL                                  THEN NULL
        WHEN c.top_100_brand_flag = 1 AND c.ape_dollars <= 0.10    THEN 1
        WHEN c.top_100_brand_flag = 1 AND c.ape_dollars >  0.10    THEN 0
        WHEN c.top_100_brand_flag = 0 AND c.ape_dollars <= 0.15    THEN 1
        WHEN c.top_100_brand_flag = 0 AND c.ape_dollars >  0.15    THEN 0
    END                                                             AS pass_flag_vs_top100_threshold,
    CASE WHEN rt.total_abs_error_dollars <> 0
        THEN ABS(c.error_dollars) / rt.total_abs_error_dollars
    END                                                             AS weighted_percent_error,
    CASE WHEN rt.total_abs_actual_dollars <> 0
        THEN ABS(c.actual_dollars) / rt.total_abs_actual_dollars
    END                                                             AS revenue_share,
    sr.revenue_quintile_desc,
    CASE WHEN c.ape_contract_price IS NOT NULL AND c.ape_contract_price < 0.20 THEN 1
         WHEN c.ape_contract_price IS NOT NULL THEN 0
         ELSE NULL
    END                                                             AS pass_flag_vs_actual_error_threshold,
    CASE WHEN c.ape_dollars IS NOT NULL
          AND ((sr.revenue_quintile_desc = 1        AND c.ape_dollars <= 0.10) OR
               (sr.revenue_quintile_desc IN (2,3,4) AND c.ape_dollars <= 0.10) OR
               (sr.revenue_quintile_desc = 5        AND c.ape_dollars <= 0.20))
         THEN 1
         WHEN c.ape_dollars IS NOT NULL THEN 0
         ELSE NULL
    END                                                             AS pass_flag_vs_materiality_threshold,
    CASE WHEN c.ape_dollars IS NOT NULL
          AND ((sr.revenue_quintile_desc = 1        AND c.ape_dollars > 0.03) OR
               (sr.revenue_quintile_desc IN (2,3,4) AND c.ape_dollars > 0.10) OR
               (sr.revenue_quintile_desc = 5        AND c.ape_dollars > 0.20))
          AND ABS(c.actual_dollars) > 0                             THEN 'CRITICAL'
         WHEN c.ape_contract_price IS NOT NULL
          AND c.ape_contract_price > 0.20                           THEN 'MODERATE'
         ELSE 'PASS'
    END                                                             AS review_priority,
    -- forecast_explosion_flag: detects runaway compounding, not large starting prices.
    -- Horizon distribution analysis showed avg_ratio flat across all forecast months
    -- (2.57-2.68 for BX, 2.59-2.63 for GX) — compounding contributes nothing.
    -- Remaining "explosions" are legitimate repricing events where
    -- latest_6_observed_avg > 2x anchor, correctly reflected in forecast_start.
    -- Fix: baseline changed from anchor_contract_price to forecast_start_contract_price.
    -- A forecast that is 2x the starting price is genuine model runaway.
    -- A forecast that equals starting_price * 1.15^2 = 1.32x is correct behavior.
    -- At ±15% cap for 2 years: max ratio vs start = 1.15^2 = 1.32x.
    -- At step history magnitude capped at 15%: same 1.32x max.
    -- 2x starting price threshold comfortably above any legitimate compounding.
    CASE WHEN c.forecasted_contract_price > 2 * c.forecast_start_contract_price
         THEN 1 ELSE 0
    END                                                             AS forecast_explosion_flag
FROM calc c
JOIN run_totals    rt ON c.run_id = rt.run_id
JOIN series_ranked sr ON c.run_id = sr.run_id AND c.groupby_key = sr.groupby_key
;


-- =====================================================================
-- EVAL SUMMARY
-- trend_cap_applied added as a GROUP BY dimension so cap-lifted
-- segment performance can be compared directly against ±2% segments.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23 AS
SELECT
    run_id,
    forecast_month,
    cust_segment,
    acct_classification,
    cust_prod_category,
    trend_cap_applied,

    COUNT(*)                                                        AS row_cnt,
    COUNT(DISTINCT groupby_key)                                     AS series_cnt,

    -- Volume
    SUM(actual_sls_qty)                                             AS actual_qty,
    SUM(actual_dollars)                                             AS actual_dollars,
    SUM(forecasted_dollars)                                         AS forecasted_dollars,

    -- Dollar bias
    SUM(forecasted_dollars - actual_dollars)                        AS error_dollars,
    SUM(forecasted_dollars - actual_dollars)
        / NULLIF(SUM(actual_dollars), 0)                            AS bias_pct,

    -- WMAPE on contract price
    SUM(ABS(forecasted_contract_price - actual_contract_price)
        * actual_sls_qty)
        / NULLIF(SUM(ABS(actual_contract_price) * actual_sls_qty), 0)
                                                                    AS wmape,

    -- MAE on contract price
    SUM(ABS(forecasted_contract_price - actual_contract_price)
        * actual_sls_qty)
        / NULLIF(SUM(actual_sls_qty), 0)                            AS mae_contract_price,

    -- Aggregate price level
    SUM(actual_dollars)
        / NULLIF(SUM(actual_sls_qty), 0)                            AS avg_actual_contract_price,
    SUM(forecasted_dollars)
        / NULLIF(SUM(actual_sls_qty), 0)                            AS avg_forecasted_contract_price,

    -- Pass rates
    COUNT_IF(pass_flag_vs_actual_error_threshold = 1)               AS pass_cnt_price,
    COUNT_IF(pass_flag_vs_actual_error_threshold = 1)
        / NULLIF(COUNT(pass_flag_vs_actual_error_threshold), 0)     AS pass_rate_price,
    COUNT_IF(pass_flag_vs_materiality_threshold  = 1)               AS pass_cnt_materiality,
    COUNT_IF(pass_flag_vs_top100_threshold       = 1)               AS pass_cnt_top100,
    COUNT_IF(pass_flag_vs_top100_threshold       = 1)
        / NULLIF(COUNT(pass_flag_vs_top100_threshold), 0)           AS pass_rate_top100,
    COUNT_IF(forecast_explosion_flag             = 1)               AS explosion_cnt

FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
GROUP BY
    run_id,
    forecast_month,
    cust_segment,
    acct_classification,
    cust_prod_category,
    trend_cap_applied
ORDER BY
    run_id,
    forecast_month,
    cust_segment,
    acct_classification,
    cust_prod_category,
    trend_cap_applied
;


-- =====================================================================
-- QA QUERIES — STEPS 5b ONWARD
-- =====================================================================

-- Q_5B_1: Confirm acct_classification source alignment
-- Rows where eligibility and step 4 disagree on acct_classification.
-- Should be 0 or very low. Non-zero indicates eligibility table
-- is sourced differently from pf_lookup in step 4.
SELECT COUNT(*) AS mismatched_rows
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v23 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23 ma
  ON ra.run_id = ma.run_id AND ra.groupby_key = ma.groupby_key
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v23 e
  ON ra.run_id = e.run_id AND ra.groupby_key = e.groupby_key
WHERE ma.acct_classification != e.acct_classification;

-- Q_5B_2: Confirm trend_cap_applied is populated
SELECT trend_cap_applied, COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v23
GROUP BY trend_cap_applied
ORDER BY row_count DESC;

-- Q_5B_3: Confirm months_since_first_asof_jumpoff is non-negative integer
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v23
WHERE months_since_first_asof_jumpoff < 0
   OR months_since_first_asof_jumpoff != CAST(months_since_first_asof_jumpoff AS INT);

-- Q_7_1: Confirm forecast_horizon_month_num is always a positive integer
-- and starts at 1 for jump_off_month rows.
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23
WHERE forecast_horizon_month_num < 1
   OR forecast_horizon_month_num != CAST(forecast_horizon_month_num AS INT);

-- Q_7_2: Confirm no duplicate run_id + groupby_key + forecast_month rows
SELECT run_id, groupby_key, forecast_month, COUNT(*) AS row_count
FROM uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v23
GROUP BY run_id, groupby_key, forecast_month
HAVING COUNT(*) > 1
ORDER BY row_count DESC
LIMIT 20;

-- Q_8_1: Confirm Fix G — WAC at jump_off vs MAX(WAC) difference
-- Shows keys where the prior MAX(WAC) approach would have differed
-- from the point-in-time jump_off WAC. Large values indicate drugs
-- with meaningful WAC increases mid-history.
SELECT
    f.groupby_key,
    f.jump_off_month,
    f.WAC                                                   AS jumpoff_wac,
    hist.max_wac,
    ROUND((hist.max_wac - f.WAC) / NULLIF(f.WAC, 0) * 100, 2) AS pct_diff
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

-- Q_8_2: Confirm no forecast_explosion_flag = 1 rows for cap-lifted segments
-- at plausible magnitudes (sanity check that 3x threshold is not firing
-- on legitimate ±15% compounded forecasts).
SELECT
    cust_prod_category,
    trend_cap_applied,
    COUNT_IF(forecast_explosion_flag = 1) AS explosion_count,
    COUNT(*) AS total_rows,
    ROUND(AVG(forecasted_contract_price / NULLIF(anchor_contract_price, 0)), 3)
        AS avg_forecast_to_anchor_ratio
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v23
GROUP BY cust_prod_category, trend_cap_applied
ORDER BY explosion_count DESC;

-- Q_EVAL_1: Summary pass rates by trend_cap_applied
-- Primary validation that cap-lifted segments improve vs ±2% baseline.
SELECT
    run_id,
    cust_prod_category,
    trend_cap_applied,
    SUM(series_cnt)                                         AS series_cnt,
    ROUND(SUM(actual_dollars) / 1e6, 1)                     AS actual_dollars_mm,
    ROUND(SUM(error_dollars) / NULLIF(SUM(actual_dollars), 0) * 100, 2)
                                                            AS bias_pct,
    ROUND(SUM(wmape * actual_dollars) / NULLIF(SUM(actual_dollars), 0) * 100, 2)
                                                            AS weighted_wmape_pct,
    ROUND(SUM(pass_cnt_materiality) / NULLIF(SUM(series_cnt), 0) * 100, 1)
                                                            AS pass_rate_materiality_pct
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
GROUP BY run_id, cust_prod_category, trend_cap_applied
ORDER BY run_id, cust_prod_category, trend_cap_applied;

-- Q_EVAL_2: Explosion flag count by segment — confirm 3x threshold
-- is not firing spuriously on cap-lifted keys.
SELECT
    cust_prod_category,
    trend_cap_applied,
    SUM(explosion_cnt)                                      AS total_explosions,
    SUM(series_cnt)                                         AS total_series,
    ROUND(SUM(explosion_cnt) / NULLIF(SUM(series_cnt), 0) * 100, 3)
                                                            AS explosion_rate_pct
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v23
GROUP BY cust_prod_category, trend_cap_applied
ORDER BY total_explosions DESC;  