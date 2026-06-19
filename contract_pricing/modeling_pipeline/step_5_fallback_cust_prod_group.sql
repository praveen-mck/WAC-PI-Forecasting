-- =========================================================
-- STEP 5A: CUSTOMER + PRODUCT GROUP FALLBACK
-- - Monthly aggregation at:
--   customer group + fallback product group
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_fallback_product_group_v2 AS
WITH monthly_group AS (
    SELECT
        customer_group_key_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        final_product_group,
        final_product_group_level,

        cal_month_start_dt,

        SUM(total_net_cos) AS total_net_cos,
        SUM(total_sls_qty) AS total_sls_qty,

        SUM(total_net_cos) / NULLIF(SUM(total_sls_qty), 0) AS contract_price,

        SUM(wac_weighted * total_sls_qty) / NULLIF(SUM(total_sls_qty), 0) AS wac_weighted,

        (
            SUM(total_net_cos) / NULLIF(SUM(wac_weighted * total_sls_qty), 0)
        ) - 1 AS wac_spread

    FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v2
    WHERE include_for_modeling_flag = 1
      AND final_product_group IS NOT NULL
      AND TRIM(final_product_group) <> ''
      AND final_product_group <> 'UNKNOWN'
    GROUP BY
        customer_group_key_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        final_product_group,
        final_product_group_level,
        cal_month_start_dt
),

last_month AS (
    SELECT
        customer_group_key_id,
        final_product_group,
        MAX(cal_month_start_dt) AS anchor_month
    FROM monthly_group
    GROUP BY
        customer_group_key_id,
        final_product_group
),

anchor_row AS (
    SELECT
        x.customer_group_key_id,
        x.final_product_group,
        x.anchor_month,
        x.contract_price AS anchor_contract_price,
        x.wac_spread AS anchor_wac_spread,
        x.total_sls_qty AS anchor_total_sls_qty,
        x.total_net_cos AS anchor_total_net_cos,
        x.cust_segment,
        x.acct_classification,
        x.cust_prod_category,
        x.final_product_group_level
    FROM (
        SELECT
            mg.*,
            ROW_NUMBER() OVER (
                PARTITION BY mg.customer_group_key_id, mg.final_product_group
                ORDER BY mg.cal_month_start_dt DESC
            ) AS rn,
            mg.cal_month_start_dt AS anchor_month
        FROM monthly_group mg
    ) x
    WHERE x.rn = 1
),

agg AS (
    SELECT
        lm.customer_group_key_id,
        lm.final_product_group,
        lm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN mg.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN mg.cal_month_start_dt
        END) AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN mg.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND mg.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN mg.cal_month_start_dt
        END) AS prior_12m_months,

        AVG(CASE
            WHEN mg.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN mg.contract_price
        END) AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN mg.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND mg.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN mg.contract_price
        END) AS prior_12m_avg_contract_price

    FROM last_month lm
    LEFT JOIN monthly_group mg
      ON lm.customer_group_key_id = mg.customer_group_key_id
     AND lm.final_product_group = mg.final_product_group
    GROUP BY
        lm.customer_group_key_id,
        lm.final_product_group,
        lm.anchor_month
)

SELECT
    a.customer_group_key_id,
    a.final_product_group,
    ar.final_product_group_level,
    ar.cust_segment,
    ar.acct_classification,
    ar.cust_prod_category,

    a.anchor_month,
    ar.anchor_contract_price,
    ar.anchor_wac_spread,
    ar.anchor_total_sls_qty,
    ar.anchor_total_net_cos,

    a.recent_12m_months,
    a.prior_12m_months,
    a.recent_12m_avg_contract_price,
    a.prior_12m_avg_contract_price,

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
        THEN 'CUSTOMER_PRODUCT_GROUP_24M_TREND'
        WHEN a.recent_12m_months >= 6
        THEN 'CUSTOMER_PRODUCT_GROUP_RECENT_ONLY'
        ELSE 'CUSTOMER_PRODUCT_GROUP_NO_SIGNAL'
    END AS fallback_source

FROM agg a
LEFT JOIN anchor_row ar
  ON a.customer_group_key_id = ar.customer_group_key_id
 AND a.final_product_group = ar.final_product_group
;
