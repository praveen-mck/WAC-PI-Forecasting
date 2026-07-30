
-- =========================================================
-- STEP 2: HISTORY PROFILE v21
-- groupby_key replaces sap_cust_num_trim+mtrl_num partitions
-- =========================================================
 
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_history_profile_v21 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21
    WHERE exclude_from_training_flag = 0
),
 
ranked AS (
    SELECT
        b.*,
        ROW_NUMBER() OVER (
            PARTITION BY b.groupby_key
            ORDER BY b.cal_month_start_dt ASC
        ) AS rn_first,
        ROW_NUMBER() OVER (
            PARTITION BY b.groupby_key
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn_last
    FROM base b
),
 
first_row AS (
    SELECT
        groupby_key,
        cal_month_start_dt AS first_month,
        contract_price     AS first_contract_price,
        wac_spread         AS first_wac_spread
    FROM ranked
    WHERE rn_first = 1
),
 
last_row AS (
    SELECT
        groupby_key,
        cal_month_start_dt AS last_month,
        contract_price     AS last_contract_price,
        wac_spread         AS last_wac_spread,
        total_sls_qty      AS last_total_sls_qty,
        total_net_cos      AS last_total_net_cos
    FROM ranked
    WHERE rn_last = 1
),
 
agg AS (
    SELECT
        groupby_key,
        MAX(sap_months)             AS sap_months,
        MAX(l2_months)              AS l2_months,
        MAX(sap_cust_num_trim)      AS sap_cust_num_trim,
        MAX(mtrl_num)               AS mtrl_num,
        MAX(CUST_SEGMENT)           AS cust_segment,
        MAX(ACCT_CLASSIFICATION)    AS acct_classification,
        MAX(CUST_PROD_CATEGORY)     AS cust_prod_category,
        MAX(NATIONAL_GRP_ID)        AS national_grp_id,
        MAX(NATIONAL_GRP_DESC)      AS national_grp_desc,
        MAX(COMMON_GRP_ID)          AS common_grp_id,
        MAX(COMMON_GRP_DESC)        AS common_grp_desc,
        MAX(subset_l2_id_resolved)  AS subset_l2_id_resolved,
        MAX(subset_l2_desc_resolved)AS subset_l2_desc_resolved,
        MAX(BRAND_NAME)             AS brand_name,
        MAX(MTRL_NME_NVGTON)        AS mtrl_nme_nvgton,
        MAX(ndc_num)                AS ndc_num,
        MAX(product_family)         AS product_family,
        MAX(therapeutic_class)      AS therapeutic_class,
        MAX(manufacturer_id)        AS manufacturer_id,
        MAX(manufacturer_name)      AS manufacturer_name,
        MAX(final_product_group)    AS final_product_group,
        MAX(CUST_NAME)              AS cust_name,
        MAX(CUST_ID)                AS cust_id,
 
        COUNT(DISTINCT cal_month_start_dt)          AS months_with_history,
        AVG(contract_price)                         AS avg_contract_price,
        percentile_approx(contract_price, 0.5)      AS median_contract_price,
        AVG(wac_spread)                             AS avg_wac_spread,
        percentile_approx(wac_spread, 0.5)          AS median_wac_spread,
        AVG(total_sls_qty)                          AS avg_monthly_qty,
        AVG(total_net_cos)                          AS avg_monthly_net_cos
    FROM base
    GROUP BY groupby_key
),
 
brand_wac_totals AS (
    SELECT
        brand_name,
        SUM(WAC) AS total_wac
    FROM base
    WHERE brand_name IS NOT NULL
    GROUP BY brand_name
),
 
top_100_brands AS (
    SELECT
        brand_name,
        ROW_NUMBER() OVER (ORDER BY total_wac DESC) AS brand_wac_rank
    FROM brand_wac_totals
    QUALIFY brand_wac_rank <= 100
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
        WHEN a.months_with_history < 6  THEN 'VERY_LOW_HISTORY'
        WHEN a.months_with_history < 12 THEN 'LOW_HISTORY'
        WHEN a.months_with_history < 24 THEN 'MEDIUM_HISTORY'
        ELSE 'HIGH_HISTORY'
    END AS history_bucket,
 
    CASE WHEN a.months_with_history < 12  THEN 1 ELSE 0 END AS is_short_history_flag,
    CASE WHEN a.months_with_history >= 12 THEN 1 ELSE 0 END AS has_min_12m_history_flag,
    CASE WHEN a.months_with_history >= 24 THEN 1 ELSE 0 END AS has_min_24m_history_flag,
 
    CASE WHEN t.brand_name IS NOT NULL THEN 1 ELSE 0 END    AS top_100_brand_flag,
    t.brand_wac_rank
 
FROM agg a
LEFT JOIN first_row f ON a.groupby_key = f.groupby_key
LEFT JOIN last_row  l ON a.groupby_key = l.groupby_key
LEFT JOIN top_100_brands t ON a.brand_name = t.brand_name
;