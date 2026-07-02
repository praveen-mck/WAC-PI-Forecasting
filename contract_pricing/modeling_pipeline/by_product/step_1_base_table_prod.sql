CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_modeling_base_v2 AS
WITH src AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.vw_q_contract_price_base
    WHERE YEAR_MONTH IS NOT NULL
      AND MTRL_NUM IS NOT NULL
      AND TRIM(MTRL_NUM) <> ''
      AND TOTAL_SLS_QTY IS NOT NULL
      AND TOTAL_SLS_QTY >= 0
),

normalized AS (
    SELECT
        TO_DATE(YEAR_MONTH || '-01') AS cal_month_start_dt,
        YEAR_MONTH,

        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,

        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        SUBSET_L2_ID,
        SUBSET_L2_DESC,


        /* optional if you add NDC upstream */
        NDC_NUM AS ndc_num,

        PRODUCT_FAMILY,
        THERAPEUTIC_CLASS,
        MANUFACTURER_ID,
        MANUFACTURER_NAME,

        TOTAL_NET_COS,
        TOTAL_SLS_QTY,
        WAC_WEIGHTED,

        /* resolved fallback attrs */
        CASE
            WHEN PRODUCT_FAMILY IS NOT NULL
             AND TRIM(PRODUCT_FAMILY) <> ''
             AND PRODUCT_FAMILY <> 'UNKNOWN'
                THEN PRODUCT_FAMILY
            WHEN THERAPEUTIC_CLASS IS NOT NULL
             AND TRIM(THERAPEUTIC_CLASS) <> ''
             AND THERAPEUTIC_CLASS <> 'UNKNOWN'
                THEN THERAPEUTIC_CLASS
            WHEN MANUFACTURER_NAME IS NOT NULL
             AND TRIM(MANUFACTURER_NAME) <> ''
             AND MANUFACTURER_NAME <> 'UNKNOWN'
                THEN MANUFACTURER_NAME
            ELSE 'UNKNOWN'
        END AS final_product_group,

        CASE
            WHEN PRODUCT_FAMILY IS NOT NULL
             AND TRIM(PRODUCT_FAMILY) <> ''
             AND PRODUCT_FAMILY <> 'UNKNOWN'
                THEN 'PRODUCT_FAMILY'
            WHEN THERAPEUTIC_CLASS IS NOT NULL
             AND TRIM(THERAPEUTIC_CLASS) <> ''
             AND THERAPEUTIC_CLASS <> 'UNKNOWN'
                THEN 'THERAPEUTIC_CLASS'
            WHEN MANUFACTURER_NAME IS NOT NULL
             AND TRIM(MANUFACTURER_NAME) <> ''
             AND MANUFACTURER_NAME <> 'UNKNOWN'
                THEN 'MANUFACTURER_NAME'
            ELSE 'UNKNOWN'
        END AS final_product_group_level,

        /* keep customer key explicit */
        CONCAT_WS('|',
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            NATIONAL_GRP_ID,
            SUBSET_L2_ID
        ) AS customer_group_key_id,

        CONCAT_WS('|',
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            NATIONAL_GRP_DESC,
            SUBSET_L2_DESC
        ) AS customer_group_key_desc

    FROM src
),

agg AS (
    SELECT
        cal_month_start_dt,
        YEAR_MONTH,

        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,

        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        SUBSET_L2_ID,
        SUBSET_L2_DESC,

        customer_group_key_id,
        customer_group_key_desc,

        MAX(ndc_num) AS ndc_num,

        MAX(PRODUCT_FAMILY) AS PRODUCT_FAMILY,
        MAX(THERAPEUTIC_CLASS) AS THERAPEUTIC_CLASS,
        MAX(MANUFACTURER_ID) AS MANUFACTURER_ID,
        MAX(MANUFACTURER_NAME) AS MANUFACTURER_NAME,
        MAX(final_product_group) AS final_product_group,
        MAX(final_product_group_level) AS final_product_group_level,

        COUNT(*) AS contributing_rows,

        SUM(TOTAL_NET_COS) AS TOTAL_NET_COS,
        SUM(TOTAL_SLS_QTY) AS TOTAL_SLS_QTY,

        /* core target */
        SUM(TOTAL_NET_COS) / NULLIF(SUM(TOTAL_SLS_QTY), 0) AS contract_price,

        /* weighted WAC */
        SUM(WAC_WEIGHTED * TOTAL_SLS_QTY) / NULLIF(SUM(TOTAL_SLS_QTY), 0) AS wac_weighted,

        /* spread retained for diagnostics / alternate modeling */
        (
            SUM(TOTAL_NET_COS)
            / NULLIF(SUM(WAC_WEIGHTED * TOTAL_SLS_QTY), 0)
        ) - 1 AS wac_spread

    FROM normalized
    GROUP BY
        cal_month_start_dt,
        YEAR_MONTH,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        SUBSET_L2_ID,
        SUBSET_L2_DESC,
        customer_group_key_id,
        customer_group_key_desc,
),

flagged AS (
    SELECT
        a.*,

        CASE WHEN contract_price < 0 THEN 1 ELSE 0 END AS negative_contract_price_flag,
        CASE WHEN TOTAL_SLS_QTY < 3 THEN 1 ELSE 0 END AS low_qty_flag,
        CASE WHEN ABS(TOTAL_NET_COS) < 1 THEN 1 ELSE 0 END AS low_ncos_flag,
        CASE WHEN wac_weighted IS NULL OR wac_weighted <= 0 THEN 1 ELSE 0 END AS invalid_wac_flag,

        CASE
            WHEN contract_price IS NULL THEN 1
            WHEN TOTAL_SLS_QTY = 0 THEN 1
            WHEN ABS(TOTAL_NET_COS) < 1 THEN 1
            WHEN TOTAL_SLS_QTY < 3 THEN 1
            WHEN contract_price < 0 THEN 1
            ELSE 0
        END AS exclude_from_training_flag

    FROM agg a
)

SELECT *
FROM flagged;
