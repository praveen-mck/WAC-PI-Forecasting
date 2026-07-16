-- =========================================================
-- STEP 2: HISTORY PROFILE
-- - One row per forecast series:
--   customer segment + class of trade + customer key + material
-- - Keeps lifecycle, latest observed price, and descriptive attrs
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_history_profile_v16 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16
),

ranked AS (
    SELECT
        b.*,
        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt ASC
        ) AS rn_first,
        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn_last
    FROM base b
),

first_row AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        cal_month_start_dt AS first_month,
        contract_price AS first_contract_price,
        wac_spread AS first_wac_spread
    FROM ranked
    WHERE rn_first = 1
),

last_row AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        cal_month_start_dt AS last_month,
        contract_price AS last_contract_price,
        wac_spread AS last_wac_spread,
        total_sls_qty AS last_total_sls_qty,
        total_net_cos AS last_total_net_cos
    FROM ranked
    WHERE rn_last = 1
),

agg AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        MAX(MODEL_TIER) AS MODEL_TIER,
        MAX(sap_months) AS SAP_MONTHS,
        MAX(l2_months) AS L2_MONTHS,
        mtrl_num,
        MAX(CUST_SEGMENT) AS cust_segment,
        MAX(ACCT_CLASSIFICATION) AS acct_classification,
        MAX(CUST_PROD_CATEGORY) AS cust_prod_category,

        MAX(NATIONAL_GRP_ID) AS national_grp_id,
        MAX(NATIONAL_GRP_DESC) AS national_grp_desc,
        MAX(BRAND_NAME) AS BRAND_NAME,
        -- MAX(customer_group_key_desc) AS customer_group_key_desc,

        MAX(MTRL_NME_NVGTON) AS mtrl_nme_nvgton,
        MAX(ndc_num) AS ndc_num,

        MAX(product_family) AS product_family,
        MAX(therapeutic_class) AS therapeutic_class,
        MAX(manufacturer_id) AS manufacturer_id,
        MAX(manufacturer_name) AS manufacturer_name,
        MAX(final_product_group) AS final_product_group,
        COUNT(DISTINCT cal_month_start_dt) AS months_with_history,
        AVG(contract_price) AS avg_contract_price,
        percentile_approx(contract_price, 0.5) AS median_contract_price,
        AVG(wac_spread) AS avg_wac_spread,
        percentile_approx(wac_spread, 0.5) AS median_wac_spread,
        AVG(total_sls_qty) AS avg_monthly_qty,
        AVG(total_net_cos) AS avg_monthly_net_cos
    FROM base
    GROUP BY
        HYBRID_MODEL_KEY_3T,
        mtrl_num
)

SELECT
    a.*,
    f.first_month,
    l.last_month,
    f.first_contract_price,
    l.last_contract_price,
    f.first_wac_spread,
    l.last_wac_spread,
    l.last_total_sls_qty,
    l.last_total_net_cos,

    CAST(months_between(l.last_month, f.first_month) AS INT) + 1 AS lifecycle_length_months,

    CASE
        WHEN a.months_with_history < 6 THEN 'VERY_LOW_HISTORY'
        WHEN a.months_with_history < 12 THEN 'LOW_HISTORY'
        WHEN a.months_with_history < 24 THEN 'MEDIUM_HISTORY'
        ELSE 'HIGH_HISTORY'
    END AS history_bucket,

    CASE WHEN a.months_with_history < 12 THEN 1 ELSE 0 END AS is_short_history_flag,
    CASE WHEN a.months_with_history >= 12 THEN 1 ELSE 0 END AS has_min_12m_history_flag,
    CASE WHEN a.months_with_history >= 24 THEN 1 ELSE 0 END AS has_min_24m_history_flag

FROM agg a
LEFT JOIN first_row f
    ON a.HYBRID_MODEL_KEY_3T = f.HYBRID_MODEL_KEY_3T
   AND a.mtrl_num = f.mtrl_num
LEFT JOIN last_row l
    ON a.HYBRID_MODEL_KEY_3T = l.HYBRID_MODEL_KEY_3T
   AND a.mtrl_num = l.mtrl_num
;
