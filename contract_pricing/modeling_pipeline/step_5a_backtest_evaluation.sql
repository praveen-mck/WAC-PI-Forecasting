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
               SUPERSEDED by Fix E below.
     Fix B  — Eval detail: actuals LEFT JOIN pre-aggregated to
               groupby_key + cal_month_start_dt before joining.
     Fix C1 — Step 5b: months_between → DATEDIFF(MONTH) for
               months_since_first_asof_jumpoff.
     Fix C2 — Step 7: months_between → DATEDIFF(MONTH) for
               forecast_horizon_month_num. This feeds the Step 8
               compounding exponent directly — incorrect truncation
               would cause the wrong number of compounding steps.
               SUPERSEDED by Fix E below (pos.n + 1 is always integer).
     Fix D  — Step 8: ROUND(horizon/3.0,0) replaces CEIL(horizon/3.0)
               to remove systematic upward bias in 340B compounding.
     Fix E  — Step 7: calendar spine now generated synthetically via
               SEQUENCE(0,59) instead of joining to modeling_base for
               dates. modeling_base only contains actuals through
               2026-08; relying on it capped the forecast at the last
               actual month rather than 60 months forward from
               jump_off_month. Supersedes Fix A and Fix C2.
     Fix F  — Step 5b: ma.trend_cap_applied added to SELECT so
               cap-lifted segment QA is available in eval tables.
     Fix G  — Step 8: WAC src join replaced with pre-materialized
               contract_price_bt_wac_jumpoff_v23 lookup table instead
               of inline subquery aggregating all of modeling_base.
               Inline subquery inflated WAC for drugs with mid-history
               increases and scanned all of modeling_base across every
               row of the 17B row Step 8 join.
     Fix H  — Step 8: LEAST() compounding caps removed from both
               branches. Price now compounds through the full 60-month
               forecast horizon. 340B quarterly cap (8 quarters) and
               annual cap (2 years) removed.
     Fix I  — Eval detail: forecast_explosion_flag threshold raised
               from 2x to 3x forecast_start_contract_price. At ±15%
               uncapped over 5 years: 1.15^5 = 2.01x, so 2x fired
               spuriously on legitimate high-trend keys.
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
-- Fix E: calendar spine now generated synthetically via SEQUENCE(0,59)
--        instead of joining to modeling_base for dates. modeling_base
--        only contains actuals through 2026-08; relying on it capped
--        the forecast at the last actual month rather than 60 months
--        forward from jump_off_month. Supersedes Fix A and Fix C2 —
--        pos.n + 1 is always an exact integer, no truncation risk.
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



-- =====================================================================
-- EVAL DETAIL
-- Fix B: actuals LEFT JOIN pre-aggregated to groupby_key +
--        cal_month_start_dt before joining.
-- Fix I: forecast_explosion_flag threshold raised from 2x to 3x
--        forecast_start_contract_price. At ±15% uncapped over 5 years:
--        1.15^5 = 2.01x, so 2x fired spuriously on legitimate keys.
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
    -- Fix I: forecast_explosion_flag threshold raised from 2x to 3x
    -- forecast_start_contract_price. At ±15% uncapped over 5 years:
    -- 1.15^5 = 2.01x vs start, so 2x threshold fired spuriously on
    -- legitimate high-trend keys. 3x is comfortably above any
    -- legitimate compounding at the ±15% cap over 60 months.
    CASE WHEN c.forecasted_contract_price > 3 * c.forecast_start_contract_price
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
