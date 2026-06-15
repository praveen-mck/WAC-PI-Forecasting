CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.vw_q_contract_price_base AS

WITH
/* =========================================================
Material master
========================================================= */
mtrl AS (
    SELECT
        MATERIAL,
        MTRL_NME_NVGTON,
        VENDOR,
        THRPTC_CLSS_CDE,
        BYNG_DESC,
        ITM_CTVTY_CDE,
        CURR_FLG,
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
Item current (for NDC and sell description)
- one row per EM_ITEM_NUM
- prefer primary NDC item, then latest update_ts
========================================================= */
item_curr AS (
    SELECT
        EM_ITEM_NUM,
        CAST(NDC_NUM AS STRING) AS NDC_NUM,
        SELL_DSCR,
        ITEM_ACTIVITY_CD,
        ITEM_ACTIVITY_DSCR,
        ITEM_SPLR_NAME
    FROM (
        SELECT
            EM_ITEM_NUM,
            NDC_NUM,
            SELL_DSCR,
            ITEM_ACTIVITY_CD,
            ITEM_ACTIVITY_DSCR,
            ITEM_SPLR_NAME,
            PRI_NDC_ITEM_FLG,
            UPDATE_TS,
            ROW_NUMBER() OVER (
                PARTITION BY EM_ITEM_NUM
                ORDER BY
                    CASE WHEN PRI_NDC_ITEM_FLG = 'Y' THEN 0 ELSE 1 END,
                    UPDATE_TS DESC
            ) AS rn
        FROM uspd_dealpricing_snowflake.edwrpt.dim_item_curr
        WHERE EM_ITEM_NUM IS NOT NULL
    ) x
    WHERE rn = 1
),

/* =========================================================
VSTX attributes
========================================================= */
vstx AS (
    SELECT
        EM_ITEM_NUM,
        THERAPEUTIC_CLASS,
        SELL_DSCR AS VSTX_SELL_DSCR,
        ATWRT_PROD_FAMILY
    FROM (
        SELECT
            EM_ITEM_NUM,
            THERAPEUTIC_CLASS,
            SELL_DSCR,
            ATWRT_PROD_FAMILY,
            ROW_NUMBER() OVER (
                PARTITION BY EM_ITEM_NUM
                ORDER BY EM_ITEM_NUM
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.T_DM_VSTX_ITEM
        WHERE EM_ITEM_NUM IS NOT NULL
    ) x
    WHERE rn = 1
),

/* =========================================================
AHFS therapeutic class
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
                PARTITION BY NULLIF(TRIM(CAST(THERA_CLS_CD AS STRING)), '')
                ORDER BY UPDT_DTS DESC
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.T_AHFS_THERA_CLS
    ) a
    WHERE rn = 1
),

/* =========================================================
Base fact
========================================================= */
base AS (
    SELECT
        DATE_FORMAT(t_copa.POST_DT, 'yyyy-MM') AS YEAR_MONTH,

        /* =====================================================
           Standardized Material ID
           ===================================================== */
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(t_copa.MTRL_NUM AS STRING), '^0+', ''), ''), '0'),
            18,
            '0'
        ) AS MTRL_NUM,

        m.MTRL_NME_NVGTON,

        /* =====================================================
           NDC from dim_item_curr
           ===================================================== */
        ic.NDC_NUM,

        /* =====================================================
           Group hierarchy with fixed-width IDs
           ===================================================== */
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(cust_mstr.COMMON_GRP_ID AS STRING), '^0+', ''), ''), '0'),
            6,
            '0'
        ) AS COMMON_GRP_ID,
        cust_mstr.COMMON_GRP_NAME AS COMMON_GRP_DESC,

        cust_mstr.CUST_CHN_ID AS CHAIN_ID,
        cust_mstr.CUST_CHN_NAME AS CHAIN_DESC,

        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(cust_mstr.NATL_GRP_CD AS STRING), '^0+', ''), ''), '0'),
            3,
            '0'
        ) AS NATIONAL_GRP_ID,
        cust_mstr.NATL_GRP_NAM AS NATIONAL_GRP_DESC,

        cust_mstr.COMMON_ENTITY_ID,
        cust_mstr.COMMON_ENTITY_NAME AS COMMON_ENTITY_DESC,

        cust_mstr.BYNG_GRP_ID,
        cust_mstr.BYNG_GRP_NAME,

        /* =====================================================
           Segment
           ===================================================== */
        CASE
            WHEN t_copa.FPA_CUST_SEG_CD IN ('A', 'B') THEN 'CP&H'
            WHEN t_copa.FPA_CUST_SEG_CD IN ('C', 'D', 'W') THEN 'SNA'
            WHEN t_copa.FPA_CUST_SEG_CD IN ('F', 'H') THEN 'MHS'
            ELSE 'INTERCO'
        END AS CUST_SEGMENT,

        /* =====================================================
           Account classification
           ===================================================== */
        CASE
            WHEN cust_mstr.ACCT_CLAS_CD = '2' THEN 'GPO'
            WHEN cust_mstr.ACCT_CLAS_CD = '4' THEN '340B-CE'
            WHEN cust_mstr.ACCT_CLAS_CD = '5' THEN '340B-CP'
            ELSE 'WAC'
        END AS ACCT_CLASSIFICATION,

        /* =====================================================
           Invoice-only
           ===================================================== */
        'Invoice' AS BILL_TYPE,

        /* =====================================================
           Customer product category
           ===================================================== */
        CASE
            WHEN t_copa.CMPNY_CD = '8545' THEN
                CASE WHEN t_copa.PROD_HIER_1_NUM = '85451' THEN 'MPB Plasma'
                     ELSE 'MPB Specialty' END
            WHEN t_copa.PROD_HIER_1_NUM IN ('00030','00050')
                 AND t_copa.SLS_CTGRY_CD NOT IN ('200','250','300','400','410','500','510') THEN 'OTC'
            WHEN t_copa.PROD_HIER_1_NUM = '00020' AND t_copa.CMPNY_CD <> '8545' THEN 'GX'
            WHEN t_copa.SLS_CTGRY_CD IN (
                '102','103','106','107','112','116',
                '122','123','701','703','711','806','807','816'
            ) THEN 'DROP SHIP'
            WHEN t_copa.MTRL_GRP2_CD = 'W2' THEN 'GLP-1'
            WHEN t_copa.MTRL_GRP2_CD IN ('R1','R2') THEN 'BIOSIMS'
            WHEN t_copa.MTRL_GRP2_CD IN ('V1','V2') THEN 'VAX'
            WHEN t_copa.MTRL_GRP2_CD IN ('S1','S3','S4','S5','S6') THEN 'APOLLO'
            ELSE 'BX'
        END AS CUST_PROD_CATEGORY,

        /* =====================================================
           Therapeutic class fix + enrichments
           ===================================================== */
        COALESCE(
            NULLIF(TRIM(v.THERAPEUTIC_CLASS), ''),
            NULLIF(TRIM(a.THERA_CLS_DSCR), ''),
            NULLIF(TRIM(m.THRPTC_CLSS_CDE), '')
        ) AS THERAPEUTIC_CLASS,

        a.THERA_CLS_DSCR AS THERAPEUTIC_CLASS_DESC,

        COALESCE(
            NULLIF(TRIM(ic.SELL_DSCR), ''),
            NULLIF(TRIM(v.VSTX_SELL_DSCR), '')
        ) AS SELL_DSCR,

        v.ATWRT_PROD_FAMILY AS PRODUCT_FAMILY,
        mf.MANUFACTURER_NAME,
        m.BYNG_DESC,
        m.THRPTC_CLSS_CDE,
        m.ITM_CTVTY_CDE,
        m.CURR_FLG AS MTRL_CURR_FLG,

        /* Optional item current enrichments */
        ic.ITEM_ACTIVITY_CD AS ITEM_CURR_ACTIVITY_CD,
        ic.ITEM_ACTIVITY_DSCR AS ITEM_CURR_ACTIVITY_DSCR,
        ic.ITEM_SPLR_NAME,

        /* =====================================================
           Measures
           ===================================================== */
        t_copa.NET_COS,
        t_copa.SLS_QTY_BEX,
        t_copa.WAC

    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa t_copa

    LEFT JOIN mtrl m
        ON t_copa.MTRL_NUM = m.MATERIAL

    LEFT JOIN mfr mf
        ON m.VENDOR = mf.VENDOR_ID

    /* =====================================================
       Join item current by de-padded material number
       ===================================================== */
    LEFT JOIN item_curr ic
        ON CAST(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(m.MATERIAL AS STRING), '^0+', ''), ''), '0')
            AS BIGINT
        ) = ic.EM_ITEM_NUM

    /* =====================================================
       Correct VSTX join
       ===================================================== */
    LEFT JOIN vstx v
        ON CAST(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(m.MATERIAL AS STRING), '^0+', ''), ''), '0')
            AS BIGINT
        ) = v.EM_ITEM_NUM

    LEFT JOIN ahfs a
        ON m.THRPTC_CLSS_CDE_CLEAN = a.THERA_CLS_CD_CLEAN

    LEFT JOIN uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr cust_mstr
        ON CAST(cust_mstr.CUST_ACCT_ID AS STRING) = RIGHT(CAST(t_copa.SAP_CUST_NUM AS STRING), 6)

    WHERE t_copa.POST_DT BETWEEN '2022-01-01' AND '2025-12-31'
      AND t_copa.CMPNY_CD IN ('8000','8545')
      AND t_copa.BUS_TYPE_CD NOT IN ('18','19','20')
      AND t_copa.SLS_QTY_BEX > 0
      AND t_copa.BILL_TYPE_CD IN ('ZPD1','ZPD5','ZPDS','ZPF2','ZPS1','ZPS3','ZPS6','ZPS7')
),

filtered AS (
    SELECT *
    FROM base
    WHERE CUST_SEGMENT <> 'INTERCO'
),

subset_normalized AS (
    SELECT
        *,
        CASE
            WHEN CUST_SEGMENT = 'MHS'  THEN COMMON_GRP_ID
            WHEN CUST_SEGMENT = 'SNA'  THEN CHAIN_ID
            WHEN CUST_SEGMENT = 'CP&H' THEN COMMON_GRP_ID
        END AS SUBSET_L2_ID,

        CASE
            WHEN CUST_SEGMENT = 'MHS'  THEN COMMON_GRP_DESC
            WHEN CUST_SEGMENT = 'SNA'  THEN CHAIN_DESC
            WHEN CUST_SEGMENT = 'CP&H' THEN COMMON_GRP_DESC
        END AS SUBSET_L2_DESC
    FROM filtered
)

SELECT
    YEAR_MONTH,
    MTRL_NUM,
    MTRL_NME_NVGTON,
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

    THERAPEUTIC_CLASS,
    THERAPEUTIC_CLASS_DESC,
    PRODUCT_FAMILY,
    SELL_DSCR,
    MANUFACTURER_NAME,

    SUM(NET_COS) / NULLIF(SUM(SLS_QTY_BEX), 0) AS CONTRACT_PRICE,
    SUM(NET_COS) AS TOTAL_NET_COS,
    SUM(SLS_QTY_BEX) AS TOTAL_SLS_QTY,
    SUM(WAC) / NULLIF(SUM(SLS_QTY_BEX), 0) AS WAC_WEIGHTED,
    (SUM(NET_COS) / NULLIF(SUM(WAC), 0)) - 1 AS WAC_SPREAD

FROM subset_normalized

GROUP BY
    YEAR_MONTH,
    MTRL_NUM,
    MTRL_NME_NVGTON,
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
    THERAPEUTIC_CLASS,
    THERAPEUTIC_CLASS_DESC,
    PRODUCT_FAMILY,
    SELL_DSCR,
    MANUFACTURER_NAME;
