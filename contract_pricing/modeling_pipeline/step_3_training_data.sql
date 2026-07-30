
 
-- =========================================================
-- STEP 3: TRAINING CLEAN v21
-- groupby_key replaces sap_cust_num_trim+mtrl_num partitions
-- =========================================================
 
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_training_clean_v21 AS
WITH base AS (
    SELECT
        b.*,
 
        ROW_NUMBER() OVER (
            PARTITION BY b.groupby_key
            ORDER BY b.cal_month_start_dt ASC
        ) AS series_month_index,
 
        COUNT(CASE WHEN b.exclude_from_training_flag = 0 THEN 1 END) OVER (
            PARTITION BY b.groupby_key
        ) AS series_valid_month_count
 
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21 b
),
 
calc AS (
    SELECT
        b.*,
        b.sap_months / NULLIF(b.l2_months, 0) AS sap_to_l2_coverage_ratio,
 
        CASE
            WHEN b.prev_month_contract_price IS NOT NULL
             AND b.prev_month_contract_price <> 0
             AND b.CUST_PROD_CATEGORY = 'GX'
             AND b.sap_months <= 3
             AND ABS(b.contract_price_mom_pct_change) > 2.00
            THEN 1
            WHEN b.prev_month_contract_price IS NOT NULL
             AND b.prev_month_contract_price <> 0
             AND NOT (b.CUST_PROD_CATEGORY = 'GX' AND b.sap_months <= 3)
             AND ABS(b.contract_price_mom_pct_change) > 0.50
            THEN 1
            ELSE 0
        END AS contract_price_change_outlier_flag
 
    FROM base b
)
 
SELECT
    c.*,
    CASE
        WHEN c.exclude_from_training_flag = 1         THEN 0
        WHEN c.contract_price_change_outlier_flag = 1 THEN 0
        ELSE 1
    END AS include_for_modeling_flag
FROM calc c
;
 