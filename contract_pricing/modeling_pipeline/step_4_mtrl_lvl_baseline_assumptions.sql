-- =========================================================
-- STEP 4: MATERIAL-LEVEL BASELINE ASSUMPTIONS
-- - One row per forecast series: customer + material
-- - No 24-month material trend category
-- - If prior 12-month history is available:
--      use prior 12-month average as baseline
-- - Else:
--      12+ observed months  -> avg latest 12 observed months
--      6-11 observed months -> avg available observed history
--      <6 observed months   -> latest observed contract price
-- - Trend is set to 0 for all material-level assumptions
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v6 AS

WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v5
    WHERE include_for_modeling_flag = 1
),

-- =========================================================
-- Find latest observed month for each customer + material
-- =========================================================
last_month AS (
    SELECT
        customer_group_key_id,
        mtrl_num,
        MAX(cal_month_start_dt) AS anchor_month
    FROM base
    GROUP BY
        customer_group_key_id,
        mtrl_num
),

-- =========================================================
-- Capture latest observed row as anchor metadata
-- =========================================================
anchor_row AS (
    SELECT
        x.customer_group_key_id,
        x.mtrl_num,
        x.cal_month_start_dt AS anchor_month,

        x.contract_price AS anchor_contract_price,
        x.wac_spread AS anchor_wac_spread,
        x.total_sls_qty AS anchor_total_sls_qty,
        x.total_net_cos AS anchor_total_net_cos,

        x.cust_segment,
        x.acct_classification,
        x.cust_prod_category,
        x.national_grp_id,
        x.national_grp_desc,
        x.customer_group_key_desc,
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
                PARTITION BY b.customer_group_key_id, b.mtrl_num
                ORDER BY b.cal_month_start_dt DESC
            ) AS rn
        FROM base b
    ) x
    WHERE x.rn = 1
),

-- =========================================================
-- Recent 12-month and prior 12-month calendar-window stats
-- relative to the anchor month
--
-- Prior 12-month window:
--   > anchor_month - 24 months
--   <= anchor_month - 12 months
-- =========================================================
calendar_window_agg AS (
    SELECT
        lm.customer_group_key_id,
        lm.mtrl_num,
        lm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN b.cal_month_start_dt
        END) AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN b.cal_month_start_dt
        END) AS prior_12m_months,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN b.contract_price
        END) AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN b.contract_price
        END) AS prior_12m_avg_contract_price,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN b.wac_spread
        END) AS recent_12m_avg_wac_spread,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN b.wac_spread
        END) AS prior_12m_avg_wac_spread,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN b.total_sls_qty
        END) AS recent_12m_avg_total_sls_qty,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN b.total_sls_qty
        END) AS prior_12m_avg_total_sls_qty,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN b.total_net_cos
        END) AS recent_12m_avg_total_net_cos,

        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND b.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN b.total_net_cos
        END) AS prior_12m_avg_total_net_cos

    FROM last_month lm
    LEFT JOIN base b
      ON lm.customer_group_key_id = b.customer_group_key_id
     AND lm.mtrl_num = b.mtrl_num
    GROUP BY
        lm.customer_group_key_id,
        lm.mtrl_num,
        lm.anchor_month
),

-- =========================================================
-- Rank all observed historical rows by recency
-- This allows fallback to the latest 12 observed months,
-- regardless of whether they are inside the recent calendar window.
-- =========================================================
ranked_history AS (
    SELECT
        b.*,
        ROW_NUMBER() OVER (
            PARTITION BY b.customer_group_key_id, b.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS history_rn
    FROM base b
),

-- =========================================================
-- Average of latest 12 observed historical months/rows
-- If fewer than 12 rows exist, this still averages available rows.
-- Later logic decides whether to use average or latest price.
-- =========================================================
latest_12_observed_agg AS (
    SELECT
        customer_group_key_id,
        mtrl_num,

        COUNT(DISTINCT cal_month_start_dt) AS latest_12_observed_months,

        AVG(contract_price) AS latest_12_observed_avg_contract_price,
        AVG(wac_spread) AS latest_12_observed_avg_wac_spread,
        AVG(total_sls_qty) AS latest_12_observed_avg_total_sls_qty,
        AVG(total_net_cos) AS latest_12_observed_avg_total_net_cos,

        MIN(cal_month_start_dt) AS latest_12_observed_start_month,
        MAX(cal_month_start_dt) AS latest_12_observed_end_month

    FROM ranked_history
    WHERE history_rn <= 12
    GROUP BY
        customer_group_key_id,
        mtrl_num
),

-- =========================================================
-- Combine all material-level signals
-- =========================================================
combined AS (
    SELECT
        cwa.customer_group_key_id,
        cwa.mtrl_num,
        cwa.anchor_month,

        cwa.recent_12m_months,
        cwa.prior_12m_months,

        cwa.recent_12m_avg_contract_price,
        cwa.prior_12m_avg_contract_price,

        cwa.recent_12m_avg_wac_spread,
        cwa.prior_12m_avg_wac_spread,

        cwa.recent_12m_avg_total_sls_qty,
        cwa.prior_12m_avg_total_sls_qty,

        cwa.recent_12m_avg_total_net_cos,
        cwa.prior_12m_avg_total_net_cos,

        l12.latest_12_observed_months,
        l12.latest_12_observed_avg_contract_price,
        l12.latest_12_observed_avg_wac_spread,
        l12.latest_12_observed_avg_total_sls_qty,
        l12.latest_12_observed_avg_total_net_cos,
        l12.latest_12_observed_start_month,
        l12.latest_12_observed_end_month

    FROM calendar_window_agg cwa
    LEFT JOIN latest_12_observed_agg l12
      ON cwa.customer_group_key_id = l12.customer_group_key_id
     AND cwa.mtrl_num = l12.mtrl_num
)

-- =========================================================
-- Final material assumptions table
-- =========================================================
SELECT
    c.customer_group_key_id,
    c.mtrl_num,

    -- Customer/product descriptors from latest observed anchor row
    ar.cust_segment,
    ar.acct_classification,
    ar.cust_prod_category,
    ar.national_grp_id,
    ar.national_grp_desc,
    ar.customer_group_key_desc,
    ar.mtrl_nme_nvgton,
    ar.ndc_num,
    ar.product_family,
    ar.therapeutic_class,
    ar.manufacturer_id,
    ar.manufacturer_name,
    ar.final_product_group,
    ar.final_product_group_level,

    -- Latest observed anchor values
    c.anchor_month,
    ar.anchor_contract_price,
    ar.anchor_wac_spread,
    ar.anchor_total_sls_qty,
    ar.anchor_total_net_cos,

    -- Calendar-window history stats
    c.recent_12m_months,
    c.prior_12m_months,

    c.recent_12m_avg_contract_price,
    c.prior_12m_avg_contract_price,

    c.recent_12m_avg_wac_spread,
    c.prior_12m_avg_wac_spread,

    c.recent_12m_avg_total_sls_qty,
    c.prior_12m_avg_total_sls_qty,

    c.recent_12m_avg_total_net_cos,
    c.prior_12m_avg_total_net_cos,

    -- Latest observed fallback stats
    c.latest_12_observed_months,
    c.latest_12_observed_start_month,
    c.latest_12_observed_end_month,
    c.latest_12_observed_avg_contract_price,
    c.latest_12_observed_avg_wac_spread,
    c.latest_12_observed_avg_total_sls_qty,
    c.latest_12_observed_avg_total_net_cos,

    -- =====================================================
    -- Forecast start contract price
    --
    -- Rule:
    -- 1. Prior 12m available with >=6 months     -> prior 12m avg
    -- 2. 12+ observed months                    -> latest 12 observed avg
    -- 3. 6-11 observed months                   -> available observed avg
    -- 4. <6 observed months                     -> latest observed price
    -- =====================================================
    CASE
        WHEN c.prior_12m_months >= 6
         AND c.prior_12m_avg_contract_price IS NOT NULL
         AND c.prior_12m_avg_contract_price > 0
        THEN c.prior_12m_avg_contract_price

        WHEN c.latest_12_observed_months >= 12
        THEN c.latest_12_observed_avg_contract_price

        WHEN c.latest_12_observed_months >= 6
        THEN c.latest_12_observed_avg_contract_price

        ELSE ar.anchor_contract_price
    END AS forecast_start_contract_price,

    -- =====================================================
    -- Forecast start WAC spread
    -- Mirrors contract price baseline logic.
    -- =====================================================
    CASE
        WHEN c.prior_12m_months >= 6
         AND c.prior_12m_avg_wac_spread IS NOT NULL
        THEN c.prior_12m_avg_wac_spread

        WHEN c.latest_12_observed_months >= 12
        THEN c.latest_12_observed_avg_wac_spread

        WHEN c.latest_12_observed_months >= 6
        THEN c.latest_12_observed_avg_wac_spread

        ELSE ar.anchor_wac_spread
    END AS forecast_start_wac_spread,

    -- =====================================================
    -- Forecast start sales quantity
    -- Mirrors contract price baseline logic.
    -- =====================================================
    CASE
        WHEN c.prior_12m_months >= 6
         AND c.prior_12m_avg_total_sls_qty IS NOT NULL
        THEN c.prior_12m_avg_total_sls_qty

        WHEN c.latest_12_observed_months >= 12
        THEN c.latest_12_observed_avg_total_sls_qty

        WHEN c.latest_12_observed_months >= 6
        THEN c.latest_12_observed_avg_total_sls_qty

        ELSE ar.anchor_total_sls_qty
    END AS forecast_start_total_sls_qty,

    -- =====================================================
    -- Forecast start net cost
    -- Mirrors contract price baseline logic.
    -- =====================================================
    CASE
        WHEN c.prior_12m_months >= 6
         AND c.prior_12m_avg_total_net_cos IS NOT NULL
        THEN c.prior_12m_avg_total_net_cos

        WHEN c.latest_12_observed_months >= 12
        THEN c.latest_12_observed_avg_total_net_cos

        WHEN c.latest_12_observed_months >= 6
        THEN c.latest_12_observed_avg_total_net_cos

        ELSE ar.anchor_total_net_cos
    END AS forecast_start_total_net_cos,

    -- =====================================================
    -- Raw monthly trend
    --
    -- 24m trend logic removed.
    -- Kept as 0 for downstream schema compatibility.
    -- =====================================================
    0 AS monthly_trend_pct_raw,

    -- =====================================================
    -- Expected monthly trend
    --
    -- 24m trend logic removed.
    -- Kept as 0 for downstream schema compatibility.
    -- =====================================================
    0 AS expected_monthly_trend_pct,

    -- =====================================================
    -- Material baseline source
    --
    -- No MATERIAL_24M_TREND category.
    -- =====================================================
    CASE
        WHEN c.prior_12m_months >= 6
         AND c.prior_12m_avg_contract_price IS NOT NULL
         AND c.prior_12m_avg_contract_price > 0
        THEN 'MATERIAL_PRIOR_12M_AVG_BASELINE'

        WHEN c.latest_12_observed_months >= 12
        THEN 'MATERIAL_LATEST_12_OBS_AVG_FALLBACK'

        WHEN c.latest_12_observed_months >= 6
        THEN 'MATERIAL_6_TO_11_OBS_AVG_FALLBACK'

        WHEN c.latest_12_observed_months > 0
        THEN 'MATERIAL_LT_6_OBS_LATEST_PRICE'

        ELSE 'MATERIAL_NO_HISTORY'
    END AS material_trend_source,

    -- =====================================================
    -- Forecast start price source for QA / explainability
    -- =====================================================
    CASE
        WHEN c.prior_12m_months >= 6
         AND c.prior_12m_avg_contract_price IS NOT NULL
         AND c.prior_12m_avg_contract_price > 0
        THEN 'AVG_PRIOR_12M_NO_TREND'

        WHEN c.latest_12_observed_months >= 12
        THEN 'AVG_LATEST_12_OBSERVED_MONTHS_NO_TREND'

        WHEN c.latest_12_observed_months >= 6
        THEN 'AVG_6_TO_11_OBSERVED_MONTHS_NO_TREND'

        WHEN c.latest_12_observed_months > 0
        THEN 'LATEST_PRICE_LT_6_OBSERVED_MONTHS_NO_TREND'

        ELSE 'NO_HISTORY_AVAILABLE'
    END AS forecast_start_price_source

FROM combined c
LEFT JOIN anchor_row ar
  ON c.customer_group_key_id = ar.customer_group_key_id
 AND c.mtrl_num = ar.mtrl_num
;