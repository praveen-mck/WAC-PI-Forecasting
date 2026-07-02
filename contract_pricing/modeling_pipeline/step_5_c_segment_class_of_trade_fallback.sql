-- =========================================================
-- STEP 5C: SEGMENT + CLASS OF TRADE + CATEGORY FALLBACK
-- - Last resort fallback
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_fallback_segment_category_v5 AS
WITH monthly_seg_cat AS (
    SELECT
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

    FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v5
    WHERE include_for_modeling_flag = 1
    GROUP BY
        cust_segment,
        acct_classification,
        cust_prod_category,
        cal_month_start_dt
),

last_month AS (
    SELECT
        cust_segment,
        acct_classification,
        cust_prod_category,
        MAX(cal_month_start_dt) AS anchor_month
    FROM monthly_seg_cat
    GROUP BY
        cust_segment,
        acct_classification,
        cust_prod_category
),

anchor_row AS (
    SELECT
        x.cust_segment,
        x.acct_classification,
        x.cust_prod_category,
        x.anchor_month,
        x.contract_price AS anchor_contract_price,
        x.wac_spread AS anchor_wac_spread
    FROM (
        SELECT
            msc.*,
            ROW_NUMBER() OVER (
                PARTITION BY msc.cust_segment, msc.acct_classification, msc.cust_prod_category
                ORDER BY msc.cal_month_start_dt DESC
            ) AS rn,
            msc.cal_month_start_dt AS anchor_month
        FROM monthly_seg_cat msc
    ) x
    WHERE x.rn = 1
),

agg AS (
    SELECT
        lm.cust_segment,
        lm.acct_classification,
        lm.cust_prod_category,
        lm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN msc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN msc.cal_month_start_dt
        END) AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN msc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND msc.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN msc.cal_month_start_dt
        END) AS prior_12m_months,

        AVG(CASE
            WHEN msc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN msc.contract_price
        END) AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN msc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND msc.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN msc.contract_price
        END) AS prior_12m_avg_contract_price

    FROM last_month lm
    LEFT JOIN monthly_seg_cat msc
      ON lm.cust_segment = msc.cust_segment
     AND lm.acct_classification = msc.acct_classification
     AND lm.cust_prod_category = msc.cust_prod_category
    GROUP BY
        lm.cust_segment,
        lm.acct_classification,
        lm.cust_prod_category,
        lm.anchor_month
)

SELECT
    a.cust_segment,
    a.acct_classification,
    a.cust_prod_category,
    a.anchor_month,
    ar.anchor_contract_price,
    ar.anchor_wac_spread,

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
        THEN 'SEGMENT_CATEGORY_24M_TREND'
        WHEN a.recent_12m_months >= 6
        THEN 'SEGMENT_CATEGORY_RECENT_ONLY'
        ELSE 'SEGMENT_CATEGORY_NO_SIGNAL'
    END AS fallback_source

FROM agg a
LEFT JOIN anchor_row ar
  ON a.cust_segment = ar.cust_segment
   AND a.acct_classification = ar.acct_classification
   AND a.cust_prod_category = ar.cust_prod_category
;
