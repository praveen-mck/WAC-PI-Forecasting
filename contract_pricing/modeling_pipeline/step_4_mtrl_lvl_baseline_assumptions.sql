-- =========================================================
-- STEP 4: MATERIAL-LEVEL BASELINE ASSUMPTIONS
-- - One row per forecast series (customer + material)
-- - Uses recent 12m vs prior 12m average contract price
-- - Anchor stays at OWN latest observed price
-- - Trend is capped conservatively to [-2%, +2%] monthly
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v2 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v2
    WHERE include_for_modeling_flag = 1
),

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
        x.subset_l2_id,
        x.subset_l2_desc,
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

agg AS (
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
        END) AS prior_12m_avg_wac_spread

    FROM last_month lm
    LEFT JOIN base b
      ON lm.customer_group_key_id = b.customer_group_key_id
     AND lm.mtrl_num = b.mtrl_num
    GROUP BY
        lm.customer_group_key_id,
        lm.mtrl_num,
        lm.anchor_month
)

SELECT
    a.customer_group_key_id,
    a.mtrl_num,

    ar.cust_segment,
    ar.acct_classification,
    ar.cust_prod_category,
    ar.national_grp_id,
    ar.national_grp_desc,
    ar.subset_l2_id,
    ar.subset_l2_desc,
    ar.customer_group_key_desc,
    ar.mtrl_nme_nvgton,
    ar.ndc_num,
    ar.product_family,
    ar.therapeutic_class,
    ar.manufacturer_id,
    ar.manufacturer_name,
    ar.final_product_group,
    ar.final_product_group_level,

    a.anchor_month,
    ar.anchor_contract_price,
    ar.anchor_wac_spread,
    ar.anchor_total_sls_qty,
    ar.anchor_total_net_cos,

    a.recent_12m_months,
    a.prior_12m_months,
    a.recent_12m_avg_contract_price,
    a.prior_12m_avg_contract_price,
    a.recent_12m_avg_wac_spread,
    a.prior_12m_avg_wac_spread,

    CASE
        WHEN a.recent_12m_months >= 6
         AND a.prior_12m_months >= 6
         AND a.prior_12m_avg_contract_price IS NOT NULL
         AND a.prior_12m_avg_contract_price > 0
        THEN POWER(
                a.recent_12m_avg_contract_price / a.prior_12m_avg_contract_price,
                1.0 / 12.0
             ) - 1
        ELSE 0
    END AS monthly_trend_pct_raw,

    CASE
        WHEN a.recent_12m_months >= 6
         AND a.prior_12m_months >= 6
         AND a.prior_12m_avg_contract_price IS NOT NULL
         AND a.prior_12m_avg_contract_price > 0
        THEN LEAST(
                GREATEST(
                    POWER(
                        a.recent_12m_avg_contract_price / a.prior_12m_avg_contract_price,
                        1.0 / 12.0
                    ) - 1,
                    -0.02
                ),
                0.02
             )
        ELSE 0
    END AS expected_monthly_trend_pct,

    CASE
        WHEN a.recent_12m_months >= 6 AND a.prior_12m_months >= 6
        THEN 'MATERIAL_24M_TREND'
        WHEN a.recent_12m_months >= 6
        THEN 'MATERIAL_LEVEL_ONLY_RECENT'
        ELSE 'MATERIAL_NO_TREND_SIGNAL'
    END AS material_trend_source

FROM agg a
LEFT JOIN anchor_row ar
  ON a.customer_group_key_id = ar.customer_group_key_id
 AND a.mtrl_num = ar.mtrl_num
;
