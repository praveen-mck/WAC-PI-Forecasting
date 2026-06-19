-- =========================================================
-- STEP 5B: CUSTOMER + PRODUCT CATEGORY FALLBACK
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_fallback_category_v2 AS
WITH monthly_cat AS (
    SELECT
        customer_group_key_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
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
    GROUP BY
        customer_group_key_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        cal_month_start_dt
),

last_month AS (
    SELECT
        customer_group_key_id,
        cust_prod_category,
        MAX(cal_month_start_dt) AS anchor_month
    FROM monthly_cat
    GROUP BY
        customer_group_key_id,
        cust_prod_category
),

anchor_row AS (
    SELECT
        x.customer_group_key_id,
        x.cust_prod_category,
        x.anchor_month,
        x.contract_price AS anchor_contract_price,
        x.wac_spread AS anchor_wac_spread,
        x.total_sls_qty AS anchor_total_sls_qty,
        x.total_net_cos AS anchor_total_net_cos,
        x.cust_segment,
        x.acct_classification
    FROM (
        SELECT
            mc.*,
            ROW_NUMBER() OVER (
                PARTITION BY mc.customer_group_key_id, mc.cust_prod_category
                ORDER BY mc.cal_month_start_dt DESC
            ) AS rn,
            mc.cal_month_start_dt AS anchor_month
        FROM monthly_cat mc
    ) x
    WHERE x.rn = 1
),

agg AS (
    SELECT
        lm.customer_group_key_id,
        lm.cust_prod_category,
        lm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN mc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN mc.cal_month_start_dt
        END) AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN mc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND mc.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN mc.cal_month_start_dt
        END) AS prior_12m_months,

        AVG(CASE
            WHEN mc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN mc.contract_price
        END) AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN mc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND mc.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN mc.contract_price
        END) AS prior_12m_avg_contract_price

    FROM last_month lm
    LEFT JOIN monthly_cat mc
      ON lm.customer_group_key_id = mc.customer_group_key_id
     AND lm.cust_prod_category = mc.cust_prod_category
    GROUP BY
        lm.customer_group_key_id,
        lm.cust_prod_category,
        lm.anchor_month
)

SELECT
    a.customer_group_key_id,
    a.cust_prod_category,
    ar.cust_segment,
    ar.acct_classification,

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
        THEN 'CUSTOMER_CATEGORY_24M_TREND'
        WHEN a.recent_12m_months >= 6
        THEN 'CUSTOMER_CATEGORY_RECENT_ONLY'
        ELSE 'CUSTOMER_CATEGORY_NO_SIGNAL'
    END AS fallback_source

FROM agg a
LEFT JOIN anchor_row ar
  ON a.customer_group_key_id = ar.customer_group_key_id
 AND a.cust_prod_category = ar.cust_prod_category
;
