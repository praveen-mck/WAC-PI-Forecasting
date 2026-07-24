-- =========================================================
-- STEP 4: MATERIAL-LEVEL BASELINE ASSUMPTIONS v20
--
-- Changes from v20:
--
--   1. APOLLO → NO_TREND OVERRIDE
--      Backtest (v14+) showed no trend was better for APOLLO.
--      AVG_YOY_PROMOTED was overriding that decision for APOLLO
--      keys with |avg_yoy| > 3%, causing -$13.8B overforecast.
--      Fix: APOLLO added as a hard override to NO_TREND in
--      assigned_trend_method, monthly_trend_pct_raw, and
--      expected_monthly_trend_pct before the sign_only block.
--
--   2. BX BASELINE UPPER-BOUND GUARD
--      208K BX keys had forecast_start_contract_price ~89% above
--      actual — their recent_6m window captured an inflated price
--      (contract reset / launch pricing) that then normalized.
--      G5 did not catch this because anchor_cp ≈ recent_6m_avg
--      (both elevated together), so anchor/latest_6_obs ≈ 1.0.
--      Fix: added upper-bound condition to all four baseline CASE
--      expressions (price, wac_spread, qty, net_cos) and the two
--      label expressions (material_trend_source,
--      forecast_start_price_source):
--        Non-GX keys: recent_6m_avg / anchor <= 1.5
--        GX exempt: generic price spikes are legitimate
--      If recent_6m_avg > anchor * 1.5, key falls back to
--      Tier2 (latest_6_obs) or Tier3 (anchor) instead of
--      using the inflated recent_6m_avg as the baseline.
--
--   Carried forward from v20:
--   - Source: contract_price_training_clean_v20
--   - avg_yoy_pct naming (was raw_avg_yoy_trend_pct)
--   - GX ratio guard bypass (anchor/recent >= 0.15)
--   - AVG_YOY_PROMOTED dampening: (avg_yoy_pct * 0.19) / 4.0
--   - G5 recency guard
--   - ±2%/qtr cap
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v20 AS

WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v20
    WHERE include_for_modeling_flag = 1
),

last_month AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(cal_month_start_dt) AS anchor_month
    FROM base
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num
),

anchor_row AS (
    SELECT
        x.HYBRID_MODEL_KEY_3T,
        x.mtrl_num,
        x.cal_month_start_dt        AS anchor_month,
        x.contract_price            AS anchor_contract_price,
        x.wac_spread                AS anchor_wac_spread,
        x.total_sls_qty             AS anchor_total_sls_qty,
        x.total_net_cos             AS anchor_total_net_cos,
        x.MODEL_TIER,
        x.sap_months,
        x.l2_months,
        x.sap_to_l2_coverage_ratio,
        x.cust_segment,
        x.acct_classification,
        x.cust_prod_category,
        x.national_grp_id,
        x.national_grp_desc,
        x.mtrl_nme_nvgton,
        x.ndc_num,
        x.product_family,
        x.therapeutic_class,
        x.manufacturer_id,
        x.manufacturer_name,
        x.final_product_group,
        x.final_product_group_level
    FROM (
        SELECT
            b.*,
            ROW_NUMBER() OVER (
                PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
                ORDER BY b.cal_month_start_dt DESC
            ) AS rn
        FROM base b
    ) x
    WHERE x.rn = 1
),

calendar_window_agg AS (
    SELECT
        lm.HYBRID_MODEL_KEY_3T,
        lm.mtrl_num,
        lm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -6)
            THEN b.cal_month_start_dt
        END)                                            AS recent_6m_months,

        COUNT(DISTINCT CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(lm.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -6)
            THEN b.cal_month_start_dt
        END)                                            AS prior_6m_months,

        NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -6)
            THEN b.total_net_cos END), 0)
        / NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -6)
            THEN b.total_sls_qty END), 0)               AS recent_6m_avg_contract_price,

        NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(lm.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -6)
            THEN b.total_net_cos END), 0)
        / NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(lm.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -6)
            THEN b.total_sls_qty END), 0)               AS prior_6m_avg_contract_price,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -6)
            THEN b.wac_spread END)                      AS recent_6m_avg_wac_spread,

        AVG(CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(lm.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -6)
            THEN b.wac_spread END)                      AS prior_6m_avg_wac_spread,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -6)
            THEN b.total_sls_qty END)                   AS recent_6m_avg_total_sls_qty,

        AVG(CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(lm.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -6)
            THEN b.total_sls_qty END)                   AS prior_6m_avg_total_sls_qty,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -6)
            THEN b.total_net_cos END)                   AS recent_6m_avg_total_net_cos,

        AVG(CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(lm.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -6)
            THEN b.total_net_cos END)                   AS prior_6m_avg_total_net_cos

    FROM last_month lm
    LEFT JOIN base b
      ON lm.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
     AND lm.mtrl_num             = b.mtrl_num
    GROUP BY lm.HYBRID_MODEL_KEY_3T, lm.mtrl_num, lm.anchor_month
),

ranked_history AS (
    SELECT
        b.*,
        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS history_rn
    FROM base b
),

latest_6_observed_agg AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        COUNT(DISTINCT cal_month_start_dt)              AS latest_6_observed_months,
        NULLIF(SUM(total_net_cos), 0)
        / NULLIF(SUM(total_sls_qty), 0)                 AS latest_6_observed_avg_contract_price,
        AVG(wac_spread)                                 AS latest_6_observed_avg_wac_spread,
        AVG(total_sls_qty)                              AS latest_6_observed_avg_total_sls_qty,
        AVG(total_net_cos)                              AS latest_6_observed_avg_total_net_cos,
        MIN(cal_month_start_dt)                         AS latest_6_observed_start_month,
        MAX(cal_month_start_dt)                         AS latest_6_observed_end_month
    FROM ranked_history
    WHERE history_rn <= 6
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num
),

quarterly_months AS (
    SELECT
        b.HYBRID_MODEL_KEY_3T,
        b.mtrl_num,
        lm.anchor_month,
        b.total_net_cos,
        b.total_sls_qty,
        CEIL(
            (DATEDIFF(MONTH, b.cal_month_start_dt, lm.anchor_month) + 1)
            / 3.0
        )                                               AS qtr_bucket
    FROM base b
    INNER JOIN last_month lm
      ON b.HYBRID_MODEL_KEY_3T = lm.HYBRID_MODEL_KEY_3T
     AND b.mtrl_num             = lm.mtrl_num
    WHERE datediff(month, b.cal_month_start_dt, lm.anchor_month) BETWEEN 0 AND 23
),

quarterly_weighted_price AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        anchor_month,
        qtr_bucket,
        NULLIF(SUM(total_net_cos), 0)
        / NULLIF(SUM(total_sls_qty), 0)                 AS qtr_price
    FROM quarterly_months
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num, anchor_month, qtr_bucket
),

yearly_months AS (
    SELECT
        b.HYBRID_MODEL_KEY_3T,
        b.mtrl_num,
        lm.anchor_month,
        b.total_net_cos,
        b.total_sls_qty,
        CEIL(
            (DATEDIFF(MONTH, b.cal_month_start_dt, lm.anchor_month) + 1)
            / 12.0
        )                                               AS yr_bucket
    FROM base b
    INNER JOIN last_month lm
      ON b.HYBRID_MODEL_KEY_3T = lm.HYBRID_MODEL_KEY_3T
     AND b.mtrl_num             = lm.mtrl_num
    WHERE DATEDIFF(MONTH, b.cal_month_start_dt, lm.anchor_month) BETWEEN 0 AND 47
),

yearly_weighted_price AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        anchor_month,
        yr_bucket,
        NULLIF(SUM(total_net_cos), 0)
        / NULLIF(SUM(total_sls_qty), 0)                 AS yr_price
    FROM yearly_months
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num, anchor_month, yr_bucket
),

yearly_yoy AS (
    SELECT
        y_curr.HYBRID_MODEL_KEY_3T,
        y_curr.mtrl_num,
        (y_curr.yr_price / NULLIF(y_prev.yr_price, 0)) - 1     AS yoy_pct,
        CASE
            WHEN (y_curr.yr_price / NULLIF(y_prev.yr_price, 0)) - 1 > 0
            THEN 1 ELSE 0
        END                                                     AS is_positive
    FROM yearly_weighted_price y_curr
    INNER JOIN yearly_weighted_price y_prev
      ON y_curr.HYBRID_MODEL_KEY_3T = y_prev.HYBRID_MODEL_KEY_3T
     AND y_curr.mtrl_num             = y_prev.mtrl_num
     AND y_curr.anchor_month         = y_prev.anchor_month
     AND y_curr.yr_bucket            = y_prev.yr_bucket - 1
    WHERE y_curr.yr_price IS NOT NULL
      AND y_prev.yr_price  IS NOT NULL
),

trend_direction AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        COUNT(*)                                        AS yoy_pairs_used,
        AVG(yoy_pct)                                    AS avg_yoy_pct,
        AVG(CAST(is_positive AS FLOAT))                 AS pct_positive_pairs,
        GREATEST(
            AVG(CAST(is_positive AS FLOAT)),
            1 - AVG(CAST(is_positive AS FLOAT))
        )                                               AS directional_consistency
    FROM yearly_yoy
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num
),

regression_inputs AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        anchor_month,
        qtr_price,
        MAX(qtr_bucket) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, mtrl_num, anchor_month
        ) - qtr_bucket                                  AS x
    FROM quarterly_weighted_price
    WHERE qtr_price IS NOT NULL
),

trend_regression AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        COUNT(*)                                        AS quarters_used,
        (COUNT(*) * SUM(x * qtr_price) - SUM(x) * SUM(qtr_price))
        / NULLIF(COUNT(*) * SUM(x * x) - SUM(x) * SUM(x), 0)
                                                        AS ols_slope,
        AVG(qtr_price)                                  AS avg_price_ref
    FROM regression_inputs
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num
),

guardrails AS (
    SELECT
        cwa.HYBRID_MODEL_KEY_3T,
        cwa.mtrl_num,

        COALESCE(td.yoy_pairs_used, 0)                  AS yoy_pairs_used,
        COALESCE(td.avg_yoy_pct, 0)                     AS avg_yoy_pct,
        COALESCE(td.pct_positive_pairs, 0.5)            AS pct_positive_pairs,
        COALESCE(td.directional_consistency, 0.5)       AS directional_consistency,

        CASE WHEN COALESCE(td.yoy_pairs_used, 0) >= 2
             THEN 1 ELSE 0 END                          AS g1_sufficient_pairs,

        CASE WHEN COALESCE(td.directional_consistency, 0) >= 0.60
             THEN 1 ELSE 0 END                          AS g2_consistent_direction,

        CASE
            WHEN cwa.recent_6m_avg_contract_price IS NULL
              OR cwa.recent_6m_avg_contract_price = 0   THEN 0
            WHEN ABS(ar.anchor_contract_price
                / NULLIF(cwa.recent_6m_avg_contract_price, 0) - 1) <= 0.20
            THEN 1 ELSE 0
        END                                             AS g3_price_stable,

        CASE
            WHEN l6.latest_6_observed_avg_contract_price IS NULL
              OR l6.latest_6_observed_avg_contract_price = 0
            THEN 1
            WHEN ar.anchor_contract_price
               / NULLIF(l6.latest_6_observed_avg_contract_price, 0) >= 0.95
            THEN 1
            ELSE 0
        END                                             AS g5_recent_price_not_falling,

        CASE
            WHEN COALESCE(td.yoy_pairs_used, 0) < 2
            THEN 0
            WHEN COALESCE(td.directional_consistency, 0) < 0.60
            THEN 0
            WHEN cwa.recent_6m_avg_contract_price IS NULL
              OR cwa.recent_6m_avg_contract_price = 0
            THEN 0
            WHEN ABS(ar.anchor_contract_price
                / NULLIF(cwa.recent_6m_avg_contract_price, 0) - 1) > 0.20
            THEN 0
            ELSE 1
        END                                             AS sign_only_eligible,

        CASE
            WHEN COALESCE(td.yoy_pairs_used, 0) = 0
            THEN 'FAIL_NO_HISTORY'
            WHEN COALESCE(td.yoy_pairs_used, 0) < 2
            THEN 'FAIL_INSUFFICIENT_PAIRS'
            WHEN COALESCE(td.directional_consistency, 0) < 0.60
            THEN 'FAIL_NOISY_DIRECTION'
            WHEN cwa.recent_6m_avg_contract_price IS NULL
              OR cwa.recent_6m_avg_contract_price = 0
            THEN 'FAIL_NO_BASELINE'
            WHEN ABS(ar.anchor_contract_price
                / NULLIF(cwa.recent_6m_avg_contract_price, 0) - 1) > 0.20
            THEN 'FAIL_PRICE_JUMP'
            ELSE 'PASS'
        END                                             AS trend_suppression_reason

    FROM calendar_window_agg cwa
    LEFT JOIN trend_direction td
      ON cwa.HYBRID_MODEL_KEY_3T = td.HYBRID_MODEL_KEY_3T
     AND cwa.mtrl_num             = td.mtrl_num
    LEFT JOIN anchor_row ar
      ON cwa.HYBRID_MODEL_KEY_3T = ar.HYBRID_MODEL_KEY_3T
     AND cwa.mtrl_num             = ar.mtrl_num
    LEFT JOIN latest_6_observed_agg l6
      ON cwa.HYBRID_MODEL_KEY_3T = l6.HYBRID_MODEL_KEY_3T
     AND cwa.mtrl_num             = l6.mtrl_num
),

combined AS (
    SELECT
        cwa.HYBRID_MODEL_KEY_3T,
        cwa.mtrl_num,
        cwa.anchor_month,
        cwa.recent_6m_months,
        cwa.prior_6m_months,
        cwa.recent_6m_avg_contract_price,
        cwa.prior_6m_avg_contract_price,
        cwa.recent_6m_avg_wac_spread,
        cwa.prior_6m_avg_wac_spread,
        cwa.recent_6m_avg_total_sls_qty,
        cwa.prior_6m_avg_total_sls_qty,
        cwa.recent_6m_avg_total_net_cos,
        cwa.prior_6m_avg_total_net_cos,

        l6.latest_6_observed_months,
        l6.latest_6_observed_avg_contract_price,
        l6.latest_6_observed_avg_wac_spread,
        l6.latest_6_observed_avg_total_sls_qty,
        l6.latest_6_observed_avg_total_net_cos,
        l6.latest_6_observed_start_month,
        l6.latest_6_observed_end_month,

        gr.yoy_pairs_used,
        gr.avg_yoy_pct,
        gr.pct_positive_pairs,
        gr.directional_consistency,
        gr.g1_sufficient_pairs,
        gr.g2_consistent_direction,
        gr.g3_price_stable,
        gr.g5_recent_price_not_falling,
        gr.sign_only_eligible,
        gr.trend_suppression_reason,

        COALESCE(tr.quarters_used, 0)           AS regression_quarters_used,
        COALESCE(
            tr.ols_slope / NULLIF(tr.avg_price_ref, 0),
        0)                                      AS raw_regression_trend_pct

    FROM calendar_window_agg cwa
    LEFT JOIN latest_6_observed_agg l6
      ON cwa.HYBRID_MODEL_KEY_3T = l6.HYBRID_MODEL_KEY_3T
     AND cwa.mtrl_num             = l6.mtrl_num
    LEFT JOIN guardrails gr
      ON cwa.HYBRID_MODEL_KEY_3T = gr.HYBRID_MODEL_KEY_3T
     AND cwa.mtrl_num             = gr.mtrl_num
    LEFT JOIN trend_regression tr
      ON cwa.HYBRID_MODEL_KEY_3T = tr.HYBRID_MODEL_KEY_3T
     AND cwa.mtrl_num             = tr.mtrl_num
)

SELECT
    c.HYBRID_MODEL_KEY_3T,
    c.mtrl_num,

    ar.MODEL_TIER,
    ar.sap_months,
    ar.l2_months,
    ar.sap_to_l2_coverage_ratio,
    ar.cust_segment,
    ar.acct_classification,
    ar.cust_prod_category,
    ar.national_grp_id,
    ar.national_grp_desc,
    ar.mtrl_nme_nvgton,
    ar.ndc_num,
    ar.product_family,
    ar.therapeutic_class,
    ar.manufacturer_id,
    ar.manufacturer_name,
    ar.final_product_group,
    ar.final_product_group_level,

    c.anchor_month,
    ar.anchor_contract_price,
    ar.anchor_wac_spread,
    ar.anchor_total_sls_qty,
    ar.anchor_total_net_cos,

    c.recent_6m_months,
    c.prior_6m_months,
    c.recent_6m_avg_contract_price,
    c.prior_6m_avg_contract_price,
    c.recent_6m_avg_wac_spread,
    c.prior_6m_avg_wac_spread,
    c.recent_6m_avg_total_sls_qty,
    c.prior_6m_avg_total_sls_qty,
    c.recent_6m_avg_total_net_cos,
    c.prior_6m_avg_total_net_cos,

    c.latest_6_observed_months,
    c.latest_6_observed_start_month,
    c.latest_6_observed_end_month,
    c.latest_6_observed_avg_contract_price,
    c.latest_6_observed_avg_wac_spread,
    c.latest_6_observed_avg_total_sls_qty,
    c.latest_6_observed_avg_total_net_cos,

    c.yoy_pairs_used,
    c.avg_yoy_pct,                              -- standardized name (was raw_avg_yoy_trend_pct)
    c.pct_positive_pairs,
    c.directional_consistency,
    c.g1_sufficient_pairs,
    c.g2_consistent_direction,
    c.g3_price_stable,
    c.g5_recent_price_not_falling,
    c.sign_only_eligible,
    c.trend_suppression_reason,
    c.regression_quarters_used,
    c.raw_regression_trend_pct,

    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_contract_price IS NOT NULL
         AND c.recent_6m_avg_contract_price > 0
         AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
              OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
         AND (c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.30
              OR ABS(c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) - 1) <= 0.05
              OR c.prior_6m_avg_contract_price > c.recent_6m_avg_contract_price * 5)
         AND (ar.cust_prod_category = 'GX'
              OR ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15)
         AND (ar.cust_prod_category = 'GX'
              OR c.recent_6m_avg_contract_price / NULLIF(ar.anchor_contract_price, 0) <= 1.5)
        THEN c.recent_6m_avg_contract_price
        WHEN c.latest_6_observed_months >= 3
        THEN c.latest_6_observed_avg_contract_price
        ELSE ar.anchor_contract_price
    END                                                 AS forecast_start_contract_price,

    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_wac_spread IS NOT NULL
         AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
              OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
         AND (c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
              OR ABS(c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) - 1) <= 0.05
              OR c.prior_6m_avg_contract_price > c.recent_6m_avg_contract_price * 5)
         AND (ar.cust_prod_category = 'GX'
              OR ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15)
         AND (ar.cust_prod_category = 'GX'
              OR c.recent_6m_avg_contract_price / NULLIF(ar.anchor_contract_price, 0) <= 1.5)
        THEN c.recent_6m_avg_wac_spread
        WHEN c.latest_6_observed_months >= 3
        THEN c.latest_6_observed_avg_wac_spread
        ELSE ar.anchor_wac_spread
    END                                                 AS forecast_start_wac_spread,

    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_total_sls_qty IS NOT NULL
         AND (c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
              OR ABS(c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) - 1) <= 0.05
              OR c.prior_6m_avg_contract_price > c.recent_6m_avg_contract_price * 5)
         AND (ar.cust_prod_category = 'GX'
              OR ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15)
         AND (ar.cust_prod_category = 'GX'
              OR c.recent_6m_avg_contract_price / NULLIF(ar.anchor_contract_price, 0) <= 1.5)
        THEN c.recent_6m_avg_total_sls_qty
        WHEN c.latest_6_observed_months >= 3
        THEN c.latest_6_observed_avg_total_sls_qty
        ELSE ar.anchor_total_sls_qty
    END                                                 AS forecast_start_total_sls_qty,

    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_total_net_cos IS NOT NULL
         AND (c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
              OR ABS(c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) - 1) <= 0.05
              OR c.prior_6m_avg_contract_price > c.recent_6m_avg_contract_price * 5)
         AND (ar.cust_prod_category = 'GX'
              OR ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15)
         AND (ar.cust_prod_category = 'GX'
              OR c.recent_6m_avg_contract_price / NULLIF(ar.anchor_contract_price, 0) <= 1.5)
        THEN c.recent_6m_avg_total_net_cos
        WHEN c.latest_6_observed_months >= 3
        THEN c.latest_6_observed_avg_total_net_cos
        ELSE ar.anchor_total_net_cos
    END                                                 AS forecast_start_total_net_cos,

    CASE
        WHEN ar.acct_classification = '340B-CP'         THEN 'REGRESSION'
        WHEN ar.cust_prod_category  = 'GLP-1'           THEN 'REGRESSION'
        WHEN ar.cust_prod_category  = 'MPB Specialty'   THEN 'AVG_YOY'
        WHEN ar.cust_prod_category  = 'APOLLO'          THEN 'NO_TREND'
        WHEN c.sign_only_eligible = 1
         AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
              OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
        THEN
            CASE
                WHEN c.g5_recent_price_not_falling = 1
                THEN CASE WHEN ABS(c.avg_yoy_pct) > 0.03 THEN 'AVG_YOY_PROMOTED'
                          ELSE 'SIGN_ONLY_025PCT' END
                WHEN c.avg_yoy_pct <= 0 THEN 'AVG_YOY_PROMOTED'
                ELSE 'NO_TREND'
            END
        ELSE 'NO_TREND'
    END                                                 AS assigned_trend_method,

    CASE
        WHEN ar.acct_classification = '340B-CP'         THEN c.raw_regression_trend_pct
        WHEN ar.cust_prod_category  = 'GLP-1'           THEN c.raw_regression_trend_pct
        WHEN ar.cust_prod_category  = 'MPB Specialty'   THEN c.avg_yoy_pct / 4.0
        WHEN ar.cust_prod_category  = 'APOLLO'          THEN 0.0
        WHEN c.sign_only_eligible = 1
         AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
              OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
        THEN
            CASE
                WHEN c.g5_recent_price_not_falling = 1
                THEN CASE WHEN ABS(c.avg_yoy_pct) > 0.03 THEN (c.avg_yoy_pct * 0.19) / 4.0
                          WHEN c.avg_yoy_pct > 0          THEN  0.0025
                          WHEN c.avg_yoy_pct < 0          THEN -0.0025
                          ELSE 0.0 END
                WHEN c.avg_yoy_pct <= 0 THEN (c.avg_yoy_pct * 0.19) / 4.0
                ELSE 0.0
            END
        ELSE 0.0
    END                                                 AS monthly_trend_pct_raw,

    GREATEST(-0.02, LEAST(0.02,
        CASE
            WHEN ar.acct_classification = '340B-CP'     THEN c.raw_regression_trend_pct
            WHEN ar.cust_prod_category  = 'GLP-1'       THEN c.raw_regression_trend_pct
            WHEN ar.cust_prod_category  = 'MPB Specialty' THEN c.avg_yoy_pct / 4.0
            WHEN ar.cust_prod_category  = 'APOLLO'      THEN 0.0
            WHEN c.sign_only_eligible = 1
             AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
                  OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
            THEN
                CASE
                    WHEN c.g5_recent_price_not_falling = 1
                    THEN CASE WHEN ABS(c.avg_yoy_pct) > 0.03 THEN (c.avg_yoy_pct * 0.19) / 4.0
                              WHEN c.avg_yoy_pct > 0          THEN  0.0025
                              WHEN c.avg_yoy_pct < 0          THEN -0.0025
                              ELSE 0.0 END
                    WHEN c.avg_yoy_pct <= 0 THEN (c.avg_yoy_pct * 0.19) / 4.0
                    ELSE 0.0
                END
            ELSE 0.0
        END
    ))                                                  AS expected_monthly_trend_pct,

    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_contract_price IS NOT NULL
         AND c.recent_6m_avg_contract_price > 0
         AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
              OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
         AND (c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
              OR ABS(c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) - 1) <= 0.05
              OR c.prior_6m_avg_contract_price > c.recent_6m_avg_contract_price * 5)
         AND (ar.cust_prod_category = 'GX'
              OR ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15)
         AND (ar.cust_prod_category = 'GX'
              OR c.recent_6m_avg_contract_price / NULLIF(ar.anchor_contract_price, 0) <= 1.5)
        THEN 'MATERIAL_RECENT_6M_AVG_BASELINE'
        WHEN c.latest_6_observed_months >= 3 THEN 'MATERIAL_LATEST_6_OBS_AVG_FALLBACK'
        WHEN c.latest_6_observed_months > 0  THEN 'MATERIAL_LT_3_OBS_LATEST_PRICE'
        ELSE 'MATERIAL_NO_HISTORY'
    END                                                 AS material_trend_source,

    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_contract_price IS NOT NULL
         AND c.recent_6m_avg_contract_price > 0
         AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
              OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
         AND (c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
              OR ABS(c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) - 1) <= 0.05
              OR c.prior_6m_avg_contract_price > c.recent_6m_avg_contract_price * 5)
         AND (ar.cust_prod_category = 'GX'
              OR ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15)
         AND (ar.cust_prod_category = 'GX'
              OR c.recent_6m_avg_contract_price / NULLIF(ar.anchor_contract_price, 0) <= 1.5)
        THEN
            CASE
                WHEN ar.acct_classification = '340B-CP' OR ar.cust_prod_category = 'GLP-1'
                THEN 'AVG_RECENT_6M_WITH_REGRESSION_TREND'
                WHEN ar.cust_prod_category = 'MPB Specialty'
                THEN 'AVG_RECENT_6M_WITH_AVG_YOY_TREND'
                WHEN c.sign_only_eligible = 1
                 AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
                      OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
                THEN
                    CASE
                        WHEN c.g5_recent_price_not_falling = 1 AND ABS(c.avg_yoy_pct) > 0.03
                        THEN 'AVG_RECENT_6M_WITH_AVG_YOY_TREND_PROMOTED'
                        WHEN c.g5_recent_price_not_falling = 1
                        THEN 'AVG_RECENT_6M_WITH_SIGN_ONLY_TREND'
                        WHEN c.avg_yoy_pct <= 0
                        THEN 'AVG_RECENT_6M_WITH_AVG_YOY_TREND_PROMOTED'
                        ELSE 'AVG_RECENT_6M_NO_TREND_G5_RECENT_PRICE_DROP'
                    END
                ELSE 'AVG_RECENT_6M_NO_TREND_' || c.trend_suppression_reason
            END
        WHEN c.latest_6_observed_months >= 3
        THEN
            CASE
                WHEN ar.acct_classification = '340B-CP' OR ar.cust_prod_category = 'GLP-1'
                THEN 'AVG_LATEST_6_OBS_WITH_REGRESSION_TREND'
                WHEN ar.cust_prod_category = 'MPB Specialty'
                THEN 'AVG_LATEST_6_OBS_WITH_AVG_YOY_TREND'
                WHEN c.sign_only_eligible = 1
                 AND (ar.anchor_wac_spread IS NULL OR c.recent_6m_avg_wac_spread IS NULL
                      OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30)
                THEN
                    CASE
                        WHEN c.g5_recent_price_not_falling = 1 AND ABS(c.avg_yoy_pct) > 0.03
                        THEN 'AVG_LATEST_6_OBS_WITH_AVG_YOY_TREND_PROMOTED'
                        WHEN c.g5_recent_price_not_falling = 1
                        THEN 'AVG_LATEST_6_OBS_WITH_SIGN_ONLY_TREND'
                        WHEN c.avg_yoy_pct <= 0
                        THEN 'AVG_LATEST_6_OBS_WITH_AVG_YOY_TREND_PROMOTED'
                        ELSE 'AVG_LATEST_6_OBS_NO_TREND_G5_RECENT_PRICE_DROP'
                    END
                ELSE 'AVG_LATEST_6_OBS_NO_TREND_' || c.trend_suppression_reason
            END
        WHEN c.latest_6_observed_months > 0
        THEN 'LATEST_PRICE_LT_3_OBSERVED_MONTHS_NO_TREND'
        ELSE 'NO_HISTORY_AVAILABLE'
    END                                                 AS forecast_start_price_source,

    CASE
        WHEN c.latest_6_observed_months >= 6 THEN 'PRICE_6MO_AVG'
        WHEN c.latest_6_observed_months >= 3 THEN 'PRICE_3_TO_5_MO_AVG'
        WHEN c.latest_6_observed_months >= 1 THEN 'PRICE_LAST_OBSERVED'
        ELSE 'NO_PRICE_AVAILABLE'
    END                                                 AS sparse_price_confidence,

    CASE
        WHEN c.latest_6_observed_months < 6 THEN 1
        ELSE 0
    END                                                 AS is_sparse_price_flag

FROM combined c
LEFT JOIN anchor_row ar
  ON c.HYBRID_MODEL_KEY_3T = ar.HYBRID_MODEL_KEY_3T
 AND c.mtrl_num             = ar.mtrl_num
;