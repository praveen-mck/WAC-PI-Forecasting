CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.vw_q_contract_price_base AS

WITH
/* =========================================================
Standardized material key
========================================================= */
base_material_key AS (
    SELECT
        t_copa.*,
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(t_copa.MTRL_NUM AS STRING), '^0+', ''), ''), '0'),
            18,
            '0'
        ) AS MTRL_NUM_STD
    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa t_copa
),

/* =========================================================
Material master
========================================================= */
mtrl AS (
    SELECT
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(MATERIAL AS STRING), '^0+', ''), ''), '0'),
            18,
            '0'
        ) AS MTRL_NUM_STD,
        MTRL_NME_NVGTON,
        VENDOR,
        THRPTC_CLSS_CDE,
        BYNG_DESC,
        NULLIF(TRIM(CAST(THRPTC_CLSS_CDE AS STRING)), '') AS THRPTC_CLSS_CDE_CLEAN
    FROM fdp_prod.psas_fdp_all_gold.vw_q_material_pharma_bw
    WHERE CURR_FLG = 'Y'
),
/* =========================================================
Manufacturer
========================================================= */
mfr AS (
    SELECT
        VENDOR_ID,
        MFG_NAME AS MANUFACTURER_NAME
    FROM fdp_prod.psas_fdp_all_gold.vw_t_manufacturer_pharma_bw
    WHERE CURR_FLG = 'Y'
),
/* =========================================================
Item current
========================================================= */
item_curr AS (
    SELECT
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
            18,
            '0'
        ) AS MTRL_NUM_STD,
        CAST(NDC_NUM AS STRING) AS NDC_NUM
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY EM_ITEM_NUM
                ORDER BY
                    CASE WHEN PRI_NDC_ITEM_FLG = 'Y' THEN 0 ELSE 1 END,
                    UPDATE_TS DESC
            ) AS rn
        FROM uspd_dealpricing_snowflake.edwrpt.dim_item_curr
    ) x
    WHERE rn = 1
),

/* =========================================================
VSTX
========================================================= */
vstx AS (
    SELECT
        MTRL_NUM_STD,
        THERAPEUTIC_CLASS,
        ATWRT_PROD_FAMILY
    FROM (
        SELECT
            LPAD(
                COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
                18,
                '0'
            ) AS MTRL_NUM_STD,
            THERAPEUTIC_CLASS,
            ATWRT_PROD_FAMILY,
            ROW_NUMBER() OVER (
                PARTITION BY EM_ITEM_NUM
                ORDER BY
                    CASE WHEN TRIM(ATWRT_PROD_FAMILY) <> '' THEN 0 ELSE 1 END
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.T_DM_VSTX_ITEM
    ) x
    WHERE rn = 1
),

/* =========================================================
AHFS
========================================================= */
ahfs AS (
    SELECT
        THERA_CLS_CD_CLEAN,
        THERA_CLS_DSCR
    FROM (
        SELECT
            NULLIF(TRIM(CAST(THERA_CLS_CD AS STRING)), '') AS THERA_CLS_CD_CLEAN,
            THERA_CLS_DSCR,
            ROW_NUMBER() OVER (
                PARTITION BY THERA_CLS_CD
                ORDER BY UPDT_DTS DESC
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.T_AHFS_THERA_CLS
    )
    WHERE rn = 1
),

/* =========================================================
Base layer
========================================================= */
base AS (
    SELECT
        DATE_FORMAT(t.POST_DT, 'yyyy-MM') AS YEAR_MONTH,
        t.MTRL_NUM_STD AS MTRL_NUM,

        m.MTRL_NME_NVGTON,
        m.VENDOR AS MANUFACTURER_ID,
        ic.NDC_NUM,

        cust_mstr.NATL_GRP_NAM AS NATIONAL_GRP_DESC,
        cust_mstr.NATL_GRP_CD AS NATIONAL_GRP_ID,

        cust_mstr.COMMON_GRP_ID,
        cust_mstr.COMMON_GRP_NAME AS COMMON_GRP_DESC,

        cust_mstr.ACCT_CHN_ID AS CHAIN_ID,
        cust_mstr.ACCT_CHN_NAME AS CHAIN_DESC,

        /* SEGMENT */
        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('A','B') THEN 'CP&H'
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN 'SNA'
            WHEN t.FPA_CUST_SEG_CD IN ('F','H') THEN 'MHS'
            ELSE 'INTERCO'
        END AS CUST_SEGMENT,

        /* ACCOUNT */
        CASE
            WHEN cust_mstr.ACCT_CLAS_CD = '2' THEN 'GPO'
            WHEN cust_mstr.ACCT_CLAS_CD = '4' THEN '340B-CE'
            WHEN cust_mstr.ACCT_CLAS_CD = '5' THEN '340B-CP'
            ELSE 'WAC'
        END AS ACCT_CLASSIFICATION,

        /* BILL TYPE */
        CASE
            WHEN t.BILL_TYPE_CD IN ('ZPD1','ZPD5','ZPDS','ZPF2','ZPS1','ZPS3','ZPS6','ZPS7') THEN 'Invoice'
            ELSE 'Other'
        END AS BILL_TYPE,

        /* PRODUCT CATEGORY */
        CASE
            WHEN t.MTRL_GRP2_CD IN ('S1','S3','S4','S5','S6') THEN 'APOLLO'
            ELSE 'BX'
        END AS CUST_PROD_CATEGORY,

        /*  PRODUCT FAMILY */
        COALESCE(
            NULLIF(TRIM(v.ATWRT_PROD_FAMILY), ''),
            NULLIF(TRIM(m.BYNG_DESC), ''),
            'UNKNOWN'
        ) AS PRODUCT_FAMILY,

        /*  THERAPEUTIC CLASS */
        COALESCE(
            NULLIF(TRIM(v.THERAPEUTIC_CLASS), ''),
            NULLIF(TRIM(a.THERA_CLS_DSCR), ''),
            NULLIF(TRIM(m.THRPTC_CLSS_CDE), ''),
            'UNKNOWN'
        ) AS THERAPEUTIC_CLASS,

        COALESCE(
        NULLIF(TRIM(mf.MANUFACTURER_NAME), ''),
        'UNKNOWN'
    ) AS MANUFACTURER_NAME,

        /* SUBSET */
        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('F','H') THEN cust_mstr.COMMON_GRP_ID
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN cust_mstr.ACCT_CHN_ID
            ELSE cust_mstr.COMMON_GRP_ID
        END AS SUBSET_L2_ID,

        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('F','H') THEN cust_mstr.COMMON_GRP_NAME
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN cust_mstr.ACCT_CHN_NAME
            ELSE cust_mstr.COMMON_GRP_NAME
        END AS SUBSET_L2_DESC,

        t.NET_COS,
        t.SLS_QTY_BEX,
        t.WAC

    FROM base_material_key t
    LEFT JOIN mtrl m  ON t.MTRL_NUM_STD = m.MTRL_NUM_STD
    LEFT JOIN mfr mf ON m.VENDOR = mf.VENDOR_ID
    LEFT JOIN item_curr ic ON t.MTRL_NUM_STD = ic.MTRL_NUM_STD
    LEFT JOIN vstx v ON t.MTRL_NUM_STD = v.MTRL_NUM_STD
    LEFT JOIN ahfs a ON m.THRPTC_CLSS_CDE_CLEAN = a.THERA_CLS_CD_CLEAN
    LEFT JOIN uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr cust_mstr
        ON RIGHT(CAST(t.SAP_CUST_NUM AS STRING),6) = CAST(cust_mstr.CUST_ACCT_ID AS STRING)
       AND cust_mstr.ACTIVE_CUST_IND = 'A'



    WHERE
        t.POST_DT BETWEEN '2022-01-01' AND '2026-05-31'
        AND t.CMPNY_CD IN ('8000','8545')
        AND t.SLS_QTY_BEX > 0
        AND t.BILL_TYPE_CD IN ('ZPD1','ZPD5','ZPDS','ZPF2','ZPS1','ZPS3','ZPS6','ZPS7')

),

/* =========================================================
Aggregation (WITH GROUP KEYS)
========================================================= */
agg AS (
    SELECT
        YEAR_MONTH,
        MTRL_NUM,
        MTRL_NME_NVGTON,
        MANUFACTURER_ID,
        MANUFACTURER_NAME,
        NDC_NUM,
        CUST_SEGMENT,
        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        SUBSET_L2_ID,
        SUBSET_L2_DESC,
        COMMON_GRP_ID,
        COMMON_GRP_DESC,
        CHAIN_ID,
        CHAIN_DESC,
        ACCT_CLASSIFICATION,
        BILL_TYPE,
        CUST_PROD_CATEGORY,
        PRODUCT_FAMILY,
        THERAPEUTIC_CLASS,

        /*  GROUP KEYS */
        CONCAT_WS('|',
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            NATIONAL_GRP_DESC,
            SUBSET_L2_DESC,
            PRODUCT_FAMILY
        ) AS GROUPBYKEY,

        CONCAT_WS('|',
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            NATIONAL_GRP_ID,
            SUBSET_L2_ID,
            PRODUCT_FAMILY
        ) AS GROUPBYKEYID,

        SUM(NET_COS) / NULLIF(SUM(SLS_QTY_BEX),0) AS CONTRACT_PRICE,
        SUM(NET_COS) AS TOTAL_NET_COS,
        SUM(SLS_QTY_BEX) AS TOTAL_SLS_QTY,
        SUM(WAC) / NULLIF(SUM(SLS_QTY_BEX),0) AS WAC_WEIGHTED

    FROM base
    WHERE CUST_SEGMENT <> 'INTERCO'
    GROUP BY ALL
)

/* =========================================================
FINAL FILTER
========================================================= */
SELECT *
FROM agg
WHERE CONTRACT_PRICE >= 0;
