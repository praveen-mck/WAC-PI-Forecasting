-- =========================================================
-- STEP 4: MATERIAL-LEVEL BASELINE ASSUMPTIONS  v16
--
-- Baseline : 6-month weighted avg (net_cos / qty)
--
-- Trend    : Yearly (YoY) as the default signal. Three
--            targeted overrides where backtesting showed a
--            stronger method materially outperforms:
--
--   Override priority (evaluated before sign-only):
--   1. acct_classification = '340B-CP'
--      -> REGRESSION (quarterly; wins clearly on small volume)
--   2. cust_prod_category  = 'GLP-1'
--      -> REGRESSION (quarterly; strong directional trend,
--                     sign-only magnitude too weak)
--   3. cust_prod_category  = 'MPB Specialty'
--      -> AVG_YOY (guardrails suppressing a real signal;
--                  AVG_YOY wins on both MAPE and MAE)
--         Applied as avg_yoy_pct / 4 so the per-quarter
--         compounding rate is consistent with the yearly
--         signal (avoids ~4x over-compounding).
--
--   Default (all other series):
--   -> SIGN_ONLY ±0.25%/qtr (0.0025) subject to guardrails:
--        G1: yoy_pairs_used >= 2
--        G2: directional_consistency >= 0.60
--        G3: ABS(anchor/baseline - 1) <= 0.20
--        G4: WAC spread drop <= -0.30
--      Any guardrail failure -> trend = 0
--
--   Note: APOLLO and VAX removed from v14 AVG_QOQ list;
--         backtesting showed no trend was better for both.
--
--   All trend values capped ±2% per quarter.
--   Applied as: baseline * (1 + trend) ^ CEIL(months_ahead/3)
--
--   Regression (340B-CP, GLP-1): intentionally kept on
--   quarterly buckets for finer granularity; slope expressed
--   as % of avg quarterly price per quarter.
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v16 AS

WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v16
    WHERE include_for_modeling_flag = 1
),

-- =========================================================
-- Find latest observed month for each hybrid key + material
-- =========================================================
last_month AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(cal_month_start_dt) AS anchor_month
    FROM base
    GROUP BY
        HYBRID_MODEL_KEY_3T,
        mtrl_num
),

-- =========================================================
-- Capture latest observed row as anchor metadata
-- =========================================================
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

-- =========================================================
-- 6-month calendar window stats
-- Contract price : weighted avg SUM(net_cos) / SUM(qty)
-- WAC spread     : simple AVG
-- Also captures prior 6m window for guard checks
-- =========================================================
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

-- =========================================================
-- Latest 6 observed months fallback
-- =========================================================
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

-- =========================================================
-- Quarterly weighted avg price (last 8 quarters = 24 months)
-- Used ONLY for regression overrides: 340B-CP and GLP-1
-- bucket 1 = most recent, bucket 8 = oldest
-- =========================================================
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

-- =========================================================
-- Yearly weighted avg price (last 4 years = 48 months)
-- Used for YoY trend direction + MPB Specialty AVG_YOY
-- bucket 1 = most recent year, bucket 4 = oldest
-- =========================================================
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

-- =========================================================
-- YoY % change + direction flag per consecutive year pair
-- Drives: sign-only guardrails, MPB Specialty AVG_YOY
-- =========================================================
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

-- =========================================================
-- Per-series YoY direction stats
-- Used by sign-only guardrails and MPB Specialty AVG_YOY
-- avg_yoy_pct is an ANNUAL rate; divided by 4 before
-- applying as a per-quarter compounding rate downstream.
-- =========================================================
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

-- =========================================================
-- OLS regression trend (340B-CP and GLP-1 overrides ONLY)
-- Intentionally kept on quarterly buckets for finer
-- granularity. Slope expressed as % of avg quarterly price
-- per quarter -- consistent with the quarterly compound
-- exponent applied downstream.
-- =========================================================
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

-- =========================================================
-- Guardrail evaluation for sign-only default
-- Only evaluated for series not covered by an override
--
-- G1: yoy_pairs_used >= 2  (yearly pairs, not quarterly)
-- G2: directional_consistency >= 0.60
-- G3: ABS(anchor / 6m_baseline - 1) <= 0.20
-- G4: WAC spread guard (inline in final SELECT)
-- =========================================================
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

        -- Combined sign-only eligibility (G1 AND G2 AND G3)
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
),

-- =========================================================
-- Combine all signals
-- =========================================================
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

        -- guardrail outputs
        gr.yoy_pairs_used,
        gr.avg_yoy_pct,
        gr.pct_positive_pairs,
        gr.directional_consistency,
        gr.g1_sufficient_pairs,
        gr.g2_consistent_direction,
        gr.g3_price_stable,
        gr.sign_only_eligible,
        gr.trend_suppression_reason,

        -- regression raw trend (quarterly; 340B-CP and GLP-1 only)
        COALESCE(tr.quarters_used, 0)                   AS regression_quarters_used,
        COALESCE(
            tr.ols_slope / NULLIF(tr.avg_price_ref, 0),
        0)                                              AS raw_regression_trend_pct

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

-- =========================================================
-- Final output
-- =========================================================
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

    -- =====================================================
    -- Guardrail diagnostics
    -- =====================================================
    c.yoy_pairs_used,
    c.avg_yoy_pct                                       AS raw_avg_yoy_trend_pct,
    c.pct_positive_pairs,
    c.directional_consistency,
    c.g1_sufficient_pairs,
    c.g2_consistent_direction,
    c.g3_price_stable,
    c.sign_only_eligible,
    c.trend_suppression_reason,
    c.regression_quarters_used,
    c.raw_regression_trend_pct,

    -- =====================================================
    -- Forecast start contract price
    -- 1. Recent 6m window (>=3 months, passes guards)
    -- 2. Latest 6 observed weighted avg (>=3 months)
    -- 3. Anchor price fallback
    -- =====================================================
    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_contract_price IS NOT NULL
         AND c.recent_6m_avg_contract_price > 0
         AND (
                ar.anchor_wac_spread IS NULL
             OR c.recent_6m_avg_wac_spread IS NULL
             OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30
             )
         AND c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.30
         AND ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15
        THEN c.recent_6m_avg_contract_price
        WHEN c.latest_6_observed_months >= 3
        THEN c.latest_6_observed_avg_contract_price
        ELSE ar.anchor_contract_price
    END                                                 AS forecast_start_contract_price,

    -- =====================================================
    -- Forecast start WAC spread
    -- =====================================================
    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_wac_spread IS NOT NULL
         AND (
                ar.anchor_wac_spread IS NULL
             OR c.recent_6m_avg_wac_spread IS NULL
             OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30
             )
         AND c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
         AND ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15
        THEN c.recent_6m_avg_wac_spread
        WHEN c.latest_6_observed_months >= 3
        THEN c.latest_6_observed_avg_wac_spread
        ELSE ar.anchor_wac_spread
    END                                                 AS forecast_start_wac_spread,

    -- =====================================================
    -- Forecast start sales quantity
    -- =====================================================
    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_total_sls_qty IS NOT NULL
         AND c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
         AND ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15
        THEN c.recent_6m_avg_total_sls_qty
        WHEN c.latest_6_observed_months >= 3
        THEN c.latest_6_observed_avg_total_sls_qty
        ELSE ar.anchor_total_sls_qty
    END                                                 AS forecast_start_total_sls_qty,

    -- =====================================================
    -- Forecast start net cost
    -- =====================================================
    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_total_net_cos IS NOT NULL
         AND c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
         AND ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15
        THEN c.recent_6m_avg_total_net_cos
        WHEN c.latest_6_observed_months >= 3
        THEN c.latest_6_observed_avg_total_net_cos
        ELSE ar.anchor_total_net_cos
    END                                                 AS forecast_start_total_net_cos,

    -- =====================================================
    -- Assigned trend method
    --
    -- Override priority:
    --   1. 340B-CP acct_classification -> REGRESSION (quarterly)
    --   2. GLP-1 cust_prod_category    -> REGRESSION (quarterly)
    --   3. MPB Specialty               -> AVG_YOY (yearly / 4)
    --
    -- Default (all others):
    --   SIGN_ONLY_025PCT if guardrails pass + WAC guard
    --   NO_TREND otherwise
    -- =====================================================
    CASE
        WHEN ar.acct_classification = '340B-CP'
        THEN 'REGRESSION'
        WHEN ar.cust_prod_category = 'GLP-1'
        THEN 'REGRESSION'
        WHEN ar.cust_prod_category = 'MPB Specialty'
        THEN 'AVG_YOY'
        WHEN c.sign_only_eligible = 1
         AND (
                ar.anchor_wac_spread IS NULL
             OR c.recent_6m_avg_wac_spread IS NULL
             OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30
             )
        THEN 'SIGN_ONLY_025PCT'
        ELSE 'NO_TREND'
    END                                                 AS assigned_trend_method,

    -- =====================================================
    -- Raw trend value (pre-cap)
    --
    -- 340B-CP / GLP-1 : quarterly OLS slope as % of avg
    --                   quarterly price (per quarter)
    -- MPB Specialty   : avg_yoy_pct / 4  -> per-quarter rate
    --                   derived from annual signal; dividing
    --                   by 4 prevents ~4x over-compounding
    --                   when applied as (1+trend)^qtr_num
    -- SIGN_ONLY       : fixed ±0.0025 per quarter
    -- NO_TREND        : 0.0
    -- =====================================================
    CASE
        WHEN ar.acct_classification = '340B-CP'
        THEN c.raw_regression_trend_pct
        WHEN ar.cust_prod_category = 'GLP-1'
        THEN c.raw_regression_trend_pct
        WHEN ar.cust_prod_category = 'MPB Specialty'
        THEN c.avg_yoy_pct / 4.0
        WHEN c.sign_only_eligible = 1
         AND (
                ar.anchor_wac_spread IS NULL
             OR c.recent_6m_avg_wac_spread IS NULL
             OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30
             )
        THEN
            CASE
                WHEN c.avg_yoy_pct > 0 THEN  0.0025
                WHEN c.avg_yoy_pct < 0 THEN -0.0025
                ELSE 0.0
            END
        ELSE 0.0
    END                                                 AS monthly_trend_pct_raw,

    -- =====================================================
    -- Expected trend: capped ±2% per quarter
    -- Applied downstream as:
    --   price * (1 + expected_monthly_trend_pct) ^ CEIL(months_ahead/3)
    --
    -- All branches express a PER-QUARTER rate so the
    -- compounding exponent is consistent across methods.
    -- =====================================================
    GREATEST(-0.02, LEAST(0.02,
        CASE
            WHEN ar.acct_classification = '340B-CP'
            THEN c.raw_regression_trend_pct
            WHEN ar.cust_prod_category = 'GLP-1'
            THEN c.raw_regression_trend_pct
            WHEN ar.cust_prod_category = 'MPB Specialty'
            THEN c.avg_yoy_pct / 4.0
            WHEN c.sign_only_eligible = 1
             AND (
                    ar.anchor_wac_spread IS NULL
                 OR c.recent_6m_avg_wac_spread IS NULL
                 OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30
                 )
            THEN
                CASE
                    WHEN c.avg_yoy_pct > 0 THEN  0.0025
                    WHEN c.avg_yoy_pct < 0 THEN -0.0025
                    ELSE 0.0
                END
            ELSE 0.0
        END
    ))                                                  AS expected_monthly_trend_pct,

    -- =====================================================
    -- Material baseline source label
    -- =====================================================
    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_contract_price IS NOT NULL
         AND c.recent_6m_avg_contract_price > 0
         AND (
                ar.anchor_wac_spread IS NULL
             OR c.recent_6m_avg_wac_spread IS NULL
             OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30
             )
         AND c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
         AND ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15
        THEN 'MATERIAL_RECENT_6M_AVG_BASELINE'
        WHEN c.latest_6_observed_months >= 3
        THEN 'MATERIAL_LATEST_6_OBS_AVG_FALLBACK'
        WHEN c.latest_6_observed_months > 0
        THEN 'MATERIAL_LT_3_OBS_LATEST_PRICE'
        ELSE 'MATERIAL_NO_HISTORY'
    END                                                 AS material_trend_source,

    -- =====================================================
    -- Forecast start price source
    -- Encodes baseline + trend method for full auditability
    -- NO_TREND labels include suppression reason
    -- =====================================================
    CASE
        WHEN c.recent_6m_months >= 3
         AND c.recent_6m_avg_contract_price IS NOT NULL
         AND c.recent_6m_avg_contract_price > 0
         AND (
                ar.anchor_wac_spread IS NULL
             OR c.recent_6m_avg_wac_spread IS NULL
             OR (ar.anchor_wac_spread - c.recent_6m_avg_wac_spread) > -0.30
             )
         AND c.recent_6m_avg_contract_price / NULLIF(c.prior_6m_avg_contract_price, 0) >= 0.40
         AND ar.anchor_contract_price / NULLIF(c.recent_6m_avg_contract_price, 0) >= 0.15
        THEN
            CASE
                WHEN ar.acct_classification = '340B-CP'
                  OR ar.cust_prod_category = 'GLP-1'
                THEN 'AVG_RECENT_6M_WITH_REGRESSION_TREND'
                WHEN ar.cust_prod_category = 'MPB Specialty'
                THEN 'AVG_RECENT_6M_WITH_AVG_YOY_TREND'
                WHEN c.sign_only_eligible = 1
                THEN 'AVG_RECENT_6M_WITH_SIGN_ONLY_TREND'
                ELSE 'AVG_RECENT_6M_NO_TREND_' || c.trend_suppression_reason
            END
        WHEN c.latest_6_observed_months >= 3
        THEN
            CASE
                WHEN ar.acct_classification = '340B-CP'
                  OR ar.cust_prod_category = 'GLP-1'
                THEN 'AVG_LATEST_6_OBS_WITH_REGRESSION_TREND'
                WHEN ar.cust_prod_category = 'MPB Specialty'
                THEN 'AVG_LATEST_6_OBS_WITH_AVG_YOY_TREND'
                WHEN c.sign_only_eligible = 1
                THEN 'AVG_LATEST_6_OBS_WITH_SIGN_ONLY_TREND'
                ELSE 'AVG_LATEST_6_OBS_NO_TREND_' || c.trend_suppression_reason
            END
        WHEN c.latest_6_observed_months > 0
        THEN 'LATEST_PRICE_LT_3_OBSERVED_MONTHS_NO_TREND'
        ELSE 'NO_HISTORY_AVAILABLE'
    END                                                 AS forecast_start_price_source

FROM combined c
LEFT JOIN anchor_row ar
  ON c.HYBRID_MODEL_KEY_3T = ar.HYBRID_MODEL_KEY_3T
 AND c.mtrl_num             = ar.mtrl_num
;