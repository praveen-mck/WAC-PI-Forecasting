CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.vw_q_contract_price_base_v16 AS

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
Material master — FIXED: added ROW_NUMBER() deduplication
========================================================= */
mtrl AS (
    SELECT
        MTRL_NUM_STD,
        MTRL_NME_NVGTON,
        THRPTC_CLSS_CDE,
        BYNG_DESC,
        NULLIF(TRIM(CAST(THRPTC_CLSS_CDE AS STRING)), '') AS THRPTC_CLSS_CDE_CLEAN
    FROM (
        SELECT
            LPAD(
                COALESCE(NULLIF(REGEXP_REPLACE(CAST(MATERIAL AS STRING), '^0+', ''), ''), '0'),
                18,
                '0'
            ) AS MTRL_NUM_STD,
            MTRL_NME_NVGTON,
            THRPTC_CLSS_CDE,
            BYNG_DESC,
            ROW_NUMBER() OVER (
                PARTITION BY
                    LPAD(
                        COALESCE(NULLIF(REGEXP_REPLACE(CAST(MATERIAL AS STRING), '^0+', ''), ''), '0'),
                        18,
                        '0'
                    )
                ORDER BY
                    CASE WHEN MTRL_NME_NVGTON IS NOT NULL AND TRIM(MTRL_NME_NVGTON) <> '' THEN 0 ELSE 1 END,
                    CASE WHEN THRPTC_CLSS_CDE IS NOT NULL AND TRIM(THRPTC_CLSS_CDE) <> '' THEN 0 ELSE 1 END,
                    MATERIAL
            ) AS rn
        FROM fdp_prod.psas_fdp_all_gold.vw_q_material_pharma_bw
        WHERE CURR_FLG = 'Y'
    ) x
    WHERE rn = 1
),

/* =========================================================
Manufacturer
========================================================= */
mfr AS (
    SELECT
        MTRL_NUM_STD,
        MANUFACTURER_ID,
        MANUFACTURER_NAME
    FROM (
        SELECT
            LPAD(
                COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
                18,
                '0'
            ) AS MTRL_NUM_STD,
            SPLR_ACCT_ID AS MANUFACTURER_ID,
            SPLR_ACCT_NAM AS MANUFACTURER_NAME,
            ROW_NUMBER() OVER (
                PARTITION BY
                    LPAD(
                        COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
                        18,
                        '0'
                    )
                ORDER BY
                    CASE WHEN SPLR_ACCT_ID IS NOT NULL THEN 0 ELSE 1 END,
                    CASE WHEN SPLR_ACCT_NAM IS NOT NULL AND TRIM(SPLR_ACCT_NAM) <> '' THEN 0 ELSE 1 END,
                    CAST(SPLR_ACCT_ID AS STRING)
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.t_iw_em_item
        WHERE SPLR_ACCT_ID IS NOT NULL
          AND ITEM_ACTVY_CD = 'A'
    ) x
    WHERE rn = 1
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
        SELECT
            *,
            ROW_NUMBER() OVER (
                PARTITION BY EM_ITEM_NUM
                ORDER BY
                    CASE WHEN PRI_NDC_ITEM_FLG = 'Y' THEN 0 ELSE 1 END,
                    UPDATE_TS DESC
            ) AS rn
        FROM uspd_dealpricing_snowflake.edwrpt.dim_item_curr
        WHERE ITEM_ACTIVITY_CD = 'A'
    ) x
    WHERE rn = 1
),

/* =========================================================
NDC brand fallback
========================================================= */
ndc AS (
    SELECT
        NDC_NUM,
        BRND_NAM
    FROM (
        SELECT
            CAST(NDC_NUM AS STRING) AS NDC_NUM,
            BRND_NAM,
            ROW_NUMBER() OVER (
                PARTITION BY CAST(NDC_NUM AS STRING)
                ORDER BY
                    CASE WHEN BRND_NAM IS NOT NULL AND TRIM(BRND_NAM) <> '' THEN 0 ELSE 1 END,
                    BRND_NAM
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.t_ndc
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
    ) x
    WHERE rn = 1
),

/* =========================================================
Base layer
========================================================= */
base_layer AS (
    SELECT
        DATE_FORMAT(t.POST_DT, 'yyyy-MM') AS YEAR_MONTH,
        t.MTRL_NUM_STD AS MTRL_NUM,

        m.MTRL_NME_NVGTON,

        mf.MANUFACTURER_ID,
        COALESCE(
            NULLIF(TRIM(mf.MANUFACTURER_NAME), ''),
            'UNKNOWN'
        ) AS MANUFACTURER_NAME,

        ic.NDC_NUM,

        cust_mstr.NATL_GRP_NAM AS NATIONAL_GRP_DESC,
        cust_mstr.NATL_GRP_CD AS NATIONAL_GRP_ID,

        cust_mstr.COMMON_GRP_ID,
        cust_mstr.COMMON_GRP_NAME AS COMMON_GRP_DESC,

        cust_mstr.ACCT_CHN_ID AS CHAIN_ID,
        cust_mstr.ACCT_CHN_NAME AS CHAIN_DESC,

        cust_mstr.CUST_ACCT_NAM AS CUST_NAME,
        cust_mstr.ACCT_CLAS_CD AS account_class_cd,

        t.FPA_CUST_SEG_CD AS CUST_SEGMENT_CD,
        t.SAP_CUST_NUM AS SAP_CUST_NUM,

        t.sap_cust_num::STRING AS raw_str,
        LPAD(RIGHT(t.sap_cust_num::STRING, 6), 6, '0') AS sap_cust_num_trim,

        cust_mstr.CUST_ACCT_ID AS CUST_ID,
        LPAD(RIGHT(cust_mstr.CUST_ACCT_ID::STRING, 6), 6, '0') AS CUST_ID_trim,

        /* SEGMENT */
        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('A','B') THEN 'CP&H'
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN 'SNA'
            WHEN t.FPA_CUST_SEG_CD IN ('F','H') THEN 'MHS'
            ELSE 'INTERCO'
        END AS CUST_SEGMENT,

        /* ACCOUNT */
        CASE
            WHEN cust_mstr.ACCT_CLAS_CD = '001' THEN 'Retail'
            WHEN cust_mstr.ACCT_CLAS_CD = '002' THEN 'GPO'
            WHEN cust_mstr.ACCT_CLAS_CD = '004' THEN '340B-CE'
            WHEN cust_mstr.ACCT_CLAS_CD = '005' THEN '340B-CP'
            ELSE 'WAC'
        END AS ACCT_CLASSIFICATION,

        /* CONTRACT TYPE */
        CASE 
            WHEN t.SLS_CTGRY_CD IN (
                '110','111','112','114','115','116','124',
                '410','510','710','711','712','814','815','816'
            )
                THEN 'Vendor Contract'
            ELSE 'Non-Vendor Contract'
        END AS CONTRACT_TYPE,

        /* ZOMBIE SALE FLAG */
        CASE 
            WHEN cust_mstr.ACCT_CLAS_CD IN ('004','005')
                 AND (
                    CASE 
                        WHEN t.SLS_CTGRY_CD IN (
                            '110','111','112','114','115','116','124',
                            '410','510','710','711','712','814','815','816'
                        )
                            THEN 'Vendor Contract'
                        ELSE 'Non-Vendor Contract'
                    END
                 ) = 'Non-Vendor Contract'
            THEN 1
            ELSE 0
        END AS ZOMBIE_SALE_FLAG,

        /* BILL TYPE */
        'Invoice' AS BILL_TYPE,

        /* PRODUCT CATEGORY */
        CASE
            WHEN t.CMPNY_CD = '8545' THEN
                CASE
                    WHEN t.PROD_HIER_1_NUM = '85451' THEN 'MPB Plasma'
                    ELSE 'MPB Specialty'
                END
            WHEN t.PROD_HIER_1_NUM IN ('00030', '00050')
                 AND t.SLS_CTGRY_CD NOT IN ('200', '250', '300', '400', '410', '500', '510')
                THEN 'OTC'
            WHEN t.PROD_HIER_1_NUM = '00020'
                 AND t.CMPNY_CD <> '8545'
                THEN 'GX'
            WHEN t.SLS_CTGRY_CD IN (
                '102', '103', '106', '107', '112', '116',
                '122', '123', '701', '703', '711', '806', '807', '816'
            )
                THEN 'DROP SHIP'
            WHEN t.MTRL_GRP2_CD = 'W2' THEN 'GLP-1'
            WHEN t.MTRL_GRP2_CD IN ('R1', 'R2') THEN 'BIOSIMS'
            WHEN t.MTRL_GRP2_CD IN ('V1', 'V2') THEN 'VAX'
            WHEN t.MTRL_GRP2_CD IN ('S1', 'S3', 'S4', 'S5', 'S6') THEN 'APOLLO'
            ELSE 'BX'
        END AS CUST_PROD_CATEGORY,
        ndc.BRND_NAM AS BRAND_NAME,

        /* PRODUCT FAMILY */
        COALESCE(
            NULLIF(TRIM(v.ATWRT_PROD_FAMILY), ''),
            NULLIF(TRIM(ndc.BRND_NAM), ''),
            NULLIF(TRIM(v.therapeutic_class),''),
            NULLIF(TRIM(a.THERA_CLS_DSCR), ''),
            NULLIF(TRIM(m.THRPTC_CLSS_CDE), ''),
            'UNKNOWN'
        ) AS PRODUCT_FAMILY,

        /* THERAPEUTIC CLASS */
        COALESCE(
            NULLIF(TRIM(v.THERAPEUTIC_CLASS), ''),
            NULLIF(TRIM(a.THERA_CLS_DSCR), ''),
            NULLIF(TRIM(m.THRPTC_CLSS_CDE), ''),
            'UNKNOWN'
        ) AS THERAPEUTIC_CLASS,

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
        t.UNIT_BILL_UOM,
        t.SLS_QTY_BEX,
        t.WAC,
        t.NET_REVENUE

    FROM base_material_key t

    INNER JOIN mtrl m
        ON t.MTRL_NUM_STD = m.MTRL_NUM_STD

    LEFT JOIN mfr mf
        ON t.MTRL_NUM_STD = mf.MTRL_NUM_STD

    INNER JOIN item_curr ic
        ON t.MTRL_NUM_STD = ic.MTRL_NUM_STD

    LEFT JOIN ndc
        ON ic.NDC_NUM = ndc.NDC_NUM

    LEFT JOIN vstx v
        ON t.MTRL_NUM_STD = v.MTRL_NUM_STD

    LEFT JOIN ahfs a
        ON m.THRPTC_CLSS_CDE_CLEAN = a.THERA_CLS_CD_CLEAN

    LEFT JOIN uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr cust_mstr
        ON LPAD(RIGHT(t.sap_cust_num::STRING, 6), 6, '0')
         = LPAD(RIGHT(cust_mstr.CUST_ACCT_ID::STRING, 6), 6, '0')
       AND cust_mstr.ACTIVE_CUST_IND = 'A'

    WHERE
        t.POST_DT BETWEEN '2022-01-01' AND '2026-05-31'
        AND t.CMPNY_CD IN ('8000','8545')
        AND t.BUS_TYPE_CD NOT IN ('18', '19', '20')
        AND t.SLS_QTY_BEX > 0
        AND t.SLS_QTY_BEX IS NOT NULL
        AND t.BILL_TYPE_CD IN ('ZPD1','ZPD5','ZPDS','ZPF2','ZPS1','ZPS3','ZPS6','ZPS7')
),

/* =========================================================
Aggregation
========================================================= */
agg AS (
    SELECT
        YEAR_MONTH,
        LTRIM(0, MTRL_NUM) AS MTRL_NUM,
        MTRL_NME_NVGTON,
        sap_cust_num,
        sap_cust_num_trim,
        cust_id,
        cust_id_trim,
        cust_name,
        MANUFACTURER_ID,
        MANUFACTURER_NAME,
        NDC_NUM,
        cust_segment_cd,
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
        account_class_cd,
        BILL_TYPE,
        CUST_PROD_CATEGORY,
        PRODUCT_FAMILY,
        BRAND_NAME,
        THERAPEUTIC_CLASS,
        CONTRACT_TYPE,

        /* PRICE / DOLLAR METRICS */
        SUM(NET_COS) / NULLIF(SUM(SLS_QTY_BEX), 0) AS CONTRACT_PRICE,
        SUM(NET_COS) AS TOTAL_NET_COS,
        SUM(SLS_QTY_BEX) AS TOTAL_SLS_QTY,
        SUM(NET_REVENUE) AS TOTAL_NET_REVENUE,
        MAX(WAC) AS WAC,
        

        SUM(CASE WHEN WAC IS NOT NULL AND SLS_QTY_BEX > 0
                THEN WAC END)
            / NULLIF(SUM(CASE WHEN WAC IS NOT NULL AND SLS_QTY_BEX > 0
                            THEN SLS_QTY_BEX END), 0) AS WAC_WEIGHTED,

        (SUM(NET_COS) / NULLIF(SUM(
            CASE WHEN WAC IS NOT NULL AND SLS_QTY_BEX > 0
                THEN WAC END
        ), 0)) - 1 AS WAC_SPREAD,

        SUM(ZOMBIE_SALE_FLAG) AS TOTAL_ZOMBIE_SALES,

        CASE 
            WHEN account_class_cd IN ('004','005')
                 AND ((SUM(NET_COS) / NULLIF(SUM(WAC * SLS_QTY_BEX), 0)) - 1) < -0.231
            THEN 'INVALID_340B'
            ELSE 'VALID'
        END AS 340B_WAC_SPREAD_FLAG

    FROM base_layer
    WHERE CUST_SEGMENT <> 'INTERCO'
    GROUP BY ALL
)

/* =========================================================
Final filter
========================================================= */
SELECT *
FROM agg
WHERE CONTRACT_PRICE > 0;