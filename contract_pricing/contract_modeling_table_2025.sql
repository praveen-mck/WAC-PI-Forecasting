CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_modeling_table_2025 AS

WITH src AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.vw_q_contract_price_base_2025
    WHERE CONTRACT_PRICE >= 0
),

/* =========================================================
   Hierarchical product fallback
   ========================================================= */
hierarchy AS (
    SELECT
        YEAR_MONTH,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        SUBSET_L2_ID,
        SUBSET_L2_DESC,

        /* keep optional descriptive columns for downstream QA / explainability */
        PRODUCT_FAMILY,
        THERAPEUTIC_CLASS,
        MANUFACTURER_ID,
        MANUFACTURER_NAME,
        MTRL_NUM,
        MTRL_NME_NVGTON,

        TOTAL_NET_COS,
        TOTAL_SLS_QTY,
        WAC_WEIGHTED,

        /* final product grouping for modeling */
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
        END AS FINAL_PRODUCT_GROUP,

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
        END AS FINAL_PRODUCT_GROUP_LEVEL
    FROM src
),

/* =========================================================
   Dedup / aggregate to modeling grain
   ========================================================= */
agg AS (
    SELECT
        YEAR_MONTH,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        SUBSET_L2_ID,
        SUBSET_L2_DESC,

        FINAL_PRODUCT_GROUP,
        FINAL_PRODUCT_GROUP_LEVEL,

        /* stable keys for modeling / reporting */
        CONCAT_WS('|',
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            NATIONAL_GRP_DESC,
            SUBSET_L2_DESC,
            FINAL_PRODUCT_GROUP
        ) AS MODEL_GROUPBYKEY,

        CONCAT_WS('|',
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            NATIONAL_GRP_ID,
            SUBSET_L2_ID,
            FINAL_PRODUCT_GROUP
        ) AS MODEL_GROUPBYKEYID,

        /* diagnostic metadata */
        COUNT(*) AS contributing_rows,
        COUNT(DISTINCT MTRL_NUM) AS distinct_materials,
        COUNT(DISTINCT MTRL_NME_NVGTON) AS distinct_material_names,
        COUNT(DISTINCT PRODUCT_FAMILY) AS distinct_product_families_in_group,
        COUNT(DISTINCT THERAPEUTIC_CLASS) AS distinct_therapeutic_classes_in_group,
        COUNT(DISTINCT MANUFACTURER_NAME) AS distinct_manufacturers_in_group,

        SUM(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'PRODUCT_FAMILY' THEN 1 ELSE 0 END) AS rows_from_product_family,
        SUM(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'THERAPEUTIC_CLASS' THEN 1 ELSE 0 END) AS rows_from_therapeutic_class,
        SUM(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'MANUFACTURER_NAME' THEN 1 ELSE 0 END) AS rows_from_manufacturer,
        SUM(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'UNKNOWN' THEN 1 ELSE 0 END) AS rows_from_unknown,

        /* proper rollup of economics */
        SUM(TOTAL_NET_COS) AS TOTAL_NET_COS,
        SUM(TOTAL_SLS_QTY) AS TOTAL_SLS_QTY,

        /* overall contract price at modeling grain */
        SUM(TOTAL_NET_COS) / NULLIF(SUM(TOTAL_SLS_QTY), 0) AS CONTRACT_PRICE,

        /* weighted WAC at modeling grain */
        SUM(WAC_WEIGHTED * TOTAL_SLS_QTY) / NULLIF(SUM(TOTAL_SLS_QTY), 0) AS WAC_WEIGHTED,

        /* consistent spread at modeling grain */
        (
            SUM(TOTAL_NET_COS)
            / NULLIF(SUM(WAC_WEIGHTED * TOTAL_SLS_QTY), 0)
        ) - 1 AS WAC_SPREAD

    FROM hierarchy
    GROUP BY
        YEAR_MONTH,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        SUBSET_L2_ID,
        SUBSET_L2_DESC,
        FINAL_PRODUCT_GROUP,
        FINAL_PRODUCT_GROUP_LEVEL
)

SELECT *
FROM agg;
