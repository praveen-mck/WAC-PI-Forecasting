
/* =========================================================
   Contract price modeling base table combine step 0 and step 1
   ========================================================= */

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_modeling_base_v18 AS

WITH

/* =========================================================
   Standardized material key
   ========================================================= */
base_material_key AS (
    SELECT
        t_copa.*,
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(t_copa.MTRL_NUM AS STRING), '^0+', ''), ''), '0'),
            18, '0'
        ) AS MTRL_NUM_STD
    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa t_copa
),

/* =========================================================
   Material master
   ========================================================= */
material_master AS (
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
                18, '0'
            ) AS MTRL_NUM_STD,
            MTRL_NME_NVGTON,
            THRPTC_CLSS_CDE,
            BYNG_DESC,
            ROW_NUMBER() OVER (
                PARTITION BY
                    LPAD(COALESCE(NULLIF(REGEXP_REPLACE(CAST(MATERIAL AS STRING), '^0+', ''), ''), '0'), 18, '0')
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
manufacturer AS (
    SELECT MTRL_NUM_STD, MANUFACTURER_ID, MANUFACTURER_NAME
    FROM (
        SELECT
            LPAD(
                COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
                18, '0'
            ) AS MTRL_NUM_STD,
            SPLR_ACCT_ID  AS MANUFACTURER_ID,
            SPLR_ACCT_NAM AS MANUFACTURER_NAME,
            ROW_NUMBER() OVER (
                PARTITION BY
                    LPAD(COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'), 18, '0')
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
   Item current — primary NDC per material
   NOTE: picks the current primary NDC; brand name on historical
   rows will reflect the current NDC if it has changed over time.
   ========================================================= */
item_curr AS (
    SELECT
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
            18, '0'
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
    SELECT NDC_NUM, BRND_NAM
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
   VSTX — FIX 1: added NULL guard on ATWRT_PROD_FAMILY
   in ORDER BY CASE to avoid NULL != '' evaluating to NULL
   ========================================================= */
vstx AS (
    SELECT MTRL_NUM_STD, THERAPEUTIC_CLASS, ATWRT_PROD_FAMILY
    FROM (
        SELECT
            LPAD(
                COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
                18, '0'
            ) AS MTRL_NUM_STD,
            THERAPEUTIC_CLASS,
            ATWRT_PROD_FAMILY,
            ROW_NUMBER() OVER (
                PARTITION BY EM_ITEM_NUM
                ORDER BY
                    -- FIX 1: was TRIM(ATWRT_PROD_FAMILY) <> '' which is NULL-unsafe
                    CASE
                        WHEN ATWRT_PROD_FAMILY IS NOT NULL
                         AND TRIM(ATWRT_PROD_FAMILY) <> ''
                        THEN 0
                        ELSE 1
                    END
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.T_DM_VSTX_ITEM
    ) x
    WHERE rn = 1
),

/* =========================================================
   AHFS therapeutic class
   ========================================================= */
ahfs AS (
    SELECT THERA_CLS_CD_CLEAN, THERA_CLS_DSCR
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
   Base layer — invoice grain before aggregation
   ========================================================= */
base_layer AS (
    SELECT
        DATE_FORMAT(t.POST_DT, 'yyyy-MM')                           AS YEAR_MONTH,
        t.MTRL_NUM_STD                                              AS MTRL_NUM,
        m.MTRL_NME_NVGTON,
        mf.MANUFACTURER_ID,
        COALESCE(NULLIF(TRIM(mf.MANUFACTURER_NAME), ''), 'UNKNOWN') AS MANUFACTURER_NAME,
        ic.NDC_NUM,
        cust_mstr.NATL_GRP_NAM                                      AS NATIONAL_GRP_DESC,
        -- FIX 8: cast to STRING to avoid type mismatch in CONCAT_WS / COALESCE downstream
        CAST(cust_mstr.NATL_GRP_CD AS STRING)                       AS NATIONAL_GRP_ID,
        cust_mstr.COMMON_GRP_ID,
        cust_mstr.COMMON_GRP_NAME                                   AS COMMON_GRP_DESC,
        cust_mstr.ACCT_CHN_ID                                       AS CHAIN_ID,
        cust_mstr.ACCT_CHN_NAME                                     AS CHAIN_DESC,
        cust_mstr.CUST_ACCT_NAM                                     AS CUST_NAME,
        cust_mstr.ACCT_CLAS_CD                                      AS account_class_cd,
        t.FPA_CUST_SEG_CD                                           AS CUST_SEGMENT_CD,
        t.SAP_CUST_NUM,
        CAST(t.sap_cust_num AS STRING)                              AS raw_str,
        LPAD(RIGHT(CAST(t.sap_cust_num AS STRING), 6), 6, '0')     AS sap_cust_num_trim,
        cust_mstr.CUST_ACCT_ID                                      AS CUST_ID,
        LPAD(RIGHT(CAST(cust_mstr.CUST_ACCT_ID AS STRING), 6), 6, '0') AS CUST_ID_trim,

        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('A','B')     THEN 'CP&H'
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN 'SNA'
            WHEN t.FPA_CUST_SEG_CD IN ('F','H')     THEN 'MHS'
            ELSE 'INTERCO'
        END AS CUST_SEGMENT,

        CASE
            WHEN cust_mstr.ACCT_CLAS_CD = '001' THEN 'Retail'
            WHEN cust_mstr.ACCT_CLAS_CD = '002' THEN 'GPO'
            WHEN cust_mstr.ACCT_CLAS_CD = '004' THEN '340B-CE'
            WHEN cust_mstr.ACCT_CLAS_CD = '005' THEN '340B-CP'
            ELSE 'WAC'
        END AS ACCT_CLASSIFICATION,

        -- Repeated in ZOMBIE_SALE_FLAG below intentionally:
        -- Spark SQL cannot forward-reference SELECT-level aliases
        CASE
            WHEN t.SLS_CTGRY_CD IN (
                '110','111','112','114','115','116','124',
                '410','510','710','711','712','814','815','816'
            ) THEN 'Vendor Contract'
            ELSE 'Non-Vendor Contract'
        END AS CONTRACT_TYPE,

        CASE
            WHEN cust_mstr.ACCT_CLAS_CD IN ('004','005')
             AND (
                CASE
                    WHEN t.SLS_CTGRY_CD IN (
                        '110','111','112','114','115','116','124',
                        '410','510','710','711','712','814','815','816'
                    ) THEN 'Vendor Contract'
                    ELSE 'Non-Vendor Contract'
                END
             ) = 'Non-Vendor Contract'
            THEN 1
            ELSE 0
        END AS ZOMBIE_SALE_FLAG,

        'Invoice' AS BILL_TYPE,

        CASE
            WHEN t.CMPNY_CD = '8545' THEN
                CASE WHEN t.PROD_HIER_1_NUM = '85451' THEN 'MPB Plasma' ELSE 'MPB Specialty' END
            WHEN t.PROD_HIER_1_NUM IN ('00030','00050')
             AND t.SLS_CTGRY_CD NOT IN ('200','250','300','400','410','500','510') THEN 'OTC'
            WHEN t.PROD_HIER_1_NUM = '00020'
             AND t.CMPNY_CD <> '8545'                                              THEN 'GX'
            WHEN t.SLS_CTGRY_CD IN (
                '102','103','106','107','112','116',
                '122','123','701','703','711','806','807','816'
            )                                                                      THEN 'DROP SHIP'
            WHEN t.MTRL_GRP2_CD = 'W2'                        THEN 'GLP-1'
            WHEN t.MTRL_GRP2_CD IN ('R1','R2')                THEN 'BIOSIMS'
            WHEN t.MTRL_GRP2_CD IN ('V1','V2')                THEN 'VAX'
            WHEN t.MTRL_GRP2_CD IN ('S1','S3','S4','S5','S6') THEN 'APOLLO'
            ELSE 'BX'
        END AS CUST_PROD_CATEGORY,

        ndc.BRND_NAM AS BRAND_NAME,

        COALESCE(
            NULLIF(TRIM(v.ATWRT_PROD_FAMILY), ''),
            NULLIF(TRIM(ndc.BRND_NAM), ''),
            NULLIF(TRIM(v.THERAPEUTIC_CLASS), ''),
            NULLIF(TRIM(a.THERA_CLS_DSCR), ''),
            NULLIF(TRIM(m.THRPTC_CLSS_CDE), ''),
            'UNKNOWN'
        ) AS PRODUCT_FAMILY,

        COALESCE(
            NULLIF(TRIM(v.THERAPEUTIC_CLASS), ''),
            NULLIF(TRIM(a.THERA_CLS_DSCR), ''),
            NULLIF(TRIM(m.THRPTC_CLSS_CDE), ''),
            'UNKNOWN'
        ) AS THERAPEUTIC_CLASS,

        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('F','H')     THEN cust_mstr.COMMON_GRP_ID
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN cust_mstr.ACCT_CHN_ID
            ELSE cust_mstr.COMMON_GRP_ID
        END AS SUBSET_L2_ID,

        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('F','H')     THEN cust_mstr.COMMON_GRP_NAME
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN cust_mstr.ACCT_CHN_NAME
            ELSE cust_mstr.COMMON_GRP_NAME
        END AS SUBSET_L2_DESC,

        t.NET_COS,
        t.UNIT_BILL_UOM,
        t.SLS_QTY_BEX,
        t.WAC,
        t.NET_REVENUE

    FROM base_material_key t

    INNER JOIN material_master m   ON t.MTRL_NUM_STD = m.MTRL_NUM_STD
    LEFT  JOIN manufacturer mf     ON t.MTRL_NUM_STD = mf.MTRL_NUM_STD
    INNER JOIN item_curr ic         ON t.MTRL_NUM_STD = ic.MTRL_NUM_STD
    LEFT  JOIN ndc                  ON ic.NDC_NUM = ndc.NDC_NUM
    LEFT  JOIN vstx v               ON t.MTRL_NUM_STD = v.MTRL_NUM_STD
    LEFT  JOIN ahfs a               ON m.THRPTC_CLSS_CDE_CLEAN = a.THERA_CLS_CD_CLEAN
    LEFT  JOIN uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr cust_mstr
        ON  LPAD(RIGHT(CAST(t.sap_cust_num AS STRING), 6), 6, '0')
          = LPAD(RIGHT(CAST(cust_mstr.CUST_ACCT_ID AS STRING), 6), 6, '0')
       AND  cust_mstr.ACTIVE_CUST_IND = 'A'

    WHERE t.POST_DT BETWEEN '2022-01-01' AND '2026-05-31'
      AND t.CMPNY_CD IN ('8000','8545')
      AND t.BUS_TYPE_CD NOT IN ('18','19','20')
      AND t.SLS_QTY_BEX > 0
      AND t.SLS_QTY_BEX IS NOT NULL
      AND t.BILL_TYPE_CD IN ('ZPD1','ZPD5','ZPDS','ZPF2','ZPS1','ZPS3','ZPS6','ZPS7')
),

/* =========================================================
   Base aggregation — formerly the view's agg + final filter
   ========================================================= */
base_agg AS (
    SELECT
        YEAR_MONTH,
        -- FIX 2 (orig FIX 1): LTRIM(0,...) invalid in Databricks
        REGEXP_REPLACE(CAST(MTRL_NUM AS STRING), '^0+', '') AS MTRL_NUM,
        MTRL_NME_NVGTON,
        SAP_CUST_NUM,
        sap_cust_num_trim,
        CUST_ID,
        CUST_ID_trim,
        CUST_NAME,
        MANUFACTURER_ID,
        MANUFACTURER_NAME,
        NDC_NUM,
        CUST_SEGMENT_CD,
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

        SUM(NET_COS) / NULLIF(SUM(SLS_QTY_BEX), 0)           AS CONTRACT_PRICE,
        SUM(NET_COS)                                           AS TOTAL_NET_COS,
        SUM(SLS_QTY_BEX)                                       AS TOTAL_SLS_QTY,
        SUM(NET_REVENUE)                                       AS TOTAL_NET_REVENUE,
        MAX(WAC)                                               AS WAC,

        SUM(CASE WHEN WAC IS NOT NULL AND SLS_QTY_BEX > 0 THEN WAC * SLS_QTY_BEX END)
            / NULLIF(SUM(CASE WHEN WAC IS NOT NULL AND SLS_QTY_BEX > 0 THEN SLS_QTY_BEX END), 0)
                                                               AS WAC_WEIGHTED,

        -- FIX 3: denominator is now quantity-weighted WAC to match WAC_WEIGHTED definition
        (
            SUM(NET_COS)
            / NULLIF(
                SUM(CASE WHEN WAC IS NOT NULL AND SLS_QTY_BEX > 0 THEN WAC * SLS_QTY_BEX END),
            0)
        ) - 1                                                  AS WAC_SPREAD,

        SUM(ZOMBIE_SALE_FLAG)                                  AS TOTAL_ZOMBIE_SALES,

        -- Combined WAC spread validity flag covering both 340B and WAC channels
        CASE
            WHEN account_class_cd IN ('004','005')
                 AND ((SUM(NET_COS) / NULLIF(SUM(WAC * SLS_QTY_BEX), 0)) - 1) < -0.231
                THEN 'INVALID_340B'
            WHEN ACCT_CLASSIFICATION = 'WAC'
                 AND ((SUM(NET_COS) / NULLIF(SUM(WAC * SLS_QTY_BEX), 0)) - 1) < -0.10
                THEN 'INVALID_WAC_SPREAD'
            ELSE 'VALID'
        END AS WAC_SPREAD_FLAG

    FROM base_layer
    WHERE CUST_SEGMENT <> 'INTERCO'
    GROUP BY ALL
),

/* =========================================================
   Source filter
   ========================================================= */
src AS (
    SELECT *
    FROM base_agg
    WHERE YEAR_MONTH        IS NOT NULL
      AND MTRL_NUM          IS NOT NULL
      AND TRIM(MTRL_NUM)    <> ''
      AND TOTAL_SLS_QTY     IS NOT NULL
      AND TOTAL_SLS_QTY     > 0
      AND TOTAL_ZOMBIE_SALES < 1
      AND WAC_SPREAD_FLAG   = 'VALID'
      AND CONTRACT_PRICE    > 0
),

/* =========================================================
   Coverage CTEs — FIX 5: explicit GROUP BY instead of GROUP BY 1
   ========================================================= */
sap_coverage AS (
    SELECT
        CONCAT_WS('|',
            MTRL_NUM, CUST_SEGMENT, ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY, COALESCE(sap_cust_num_trim, 'NA')
        ) AS sap_key,
        COUNT(DISTINCT YEAR_MONTH) AS sap_months
    FROM src
    GROUP BY
        CONCAT_WS('|',
            MTRL_NUM, CUST_SEGMENT, ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY, COALESCE(sap_cust_num_trim, 'NA')
        )
),

l2_coverage AS (
    SELECT
        CONCAT_WS('|',
            MTRL_NUM, CUST_SEGMENT, ACCT_CLASSIFICATION, CUST_PROD_CATEGORY,
            COALESCE(
                CASE
                    WHEN CUST_SEGMENT_CD IN ('F','H')     THEN CAST(COMMON_GRP_ID AS STRING)
                    WHEN CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(CHAIN_ID AS STRING)
                    ELSE CAST(COMMON_GRP_ID AS STRING)
                END,
            'NA')
        ) AS l2_key,
        COUNT(DISTINCT YEAR_MONTH) AS l2_months
    FROM src
    GROUP BY
        CONCAT_WS('|',
            MTRL_NUM, CUST_SEGMENT, ACCT_CLASSIFICATION, CUST_PROD_CATEGORY,
            COALESCE(
                CASE
                    WHEN CUST_SEGMENT_CD IN ('F','H')     THEN CAST(COMMON_GRP_ID AS STRING)
                    WHEN CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(CHAIN_ID AS STRING)
                    ELSE CAST(COMMON_GRP_ID AS STRING)
                END,
            'NA')
        )
),

/* =========================================================
   Normalized — row-level enrichment before re-aggregation
   ========================================================= */
normalized AS (
    SELECT
        TO_DATE(CONCAT(s.YEAR_MONTH, '-01'))    AS cal_month_start_dt,
        s.YEAR_MONTH,
        s.CUST_SEGMENT,
        s.CUST_SEGMENT_CD,
        s.CUST_NAME,
        s.ACCT_CLASSIFICATION,
        s.account_class_cd,
        s.CUST_PROD_CATEGORY,
        s.NATIONAL_GRP_ID,
        s.NATIONAL_GRP_DESC,
        s.COMMON_GRP_ID,
        s.COMMON_GRP_DESC,
        s.CHAIN_ID,
        s.CHAIN_DESC,
        s.SUBSET_L2_ID,
        s.SUBSET_L2_DESC,
        s.MTRL_NUM,
        s.MTRL_NME_NVGTON,
        s.NDC_NUM                               AS ndc_num,
        s.WAC,
        s.TOTAL_NET_REVENUE,
        s.BRAND_NAME,
        s.PRODUCT_FAMILY,
        s.THERAPEUTIC_CLASS,
        s.MANUFACTURER_ID,
        s.MANUFACTURER_NAME,
        s.TOTAL_NET_COS,
        s.TOTAL_SLS_QTY,
        s.WAC_WEIGHTED,

        CASE
            WHEN s.PRODUCT_FAMILY    IS NOT NULL AND TRIM(s.PRODUCT_FAMILY)    NOT IN ('','UNKNOWN') THEN s.PRODUCT_FAMILY
            WHEN s.THERAPEUTIC_CLASS IS NOT NULL AND TRIM(s.THERAPEUTIC_CLASS) NOT IN ('','UNKNOWN') THEN s.THERAPEUTIC_CLASS
            WHEN s.MANUFACTURER_NAME IS NOT NULL AND TRIM(s.MANUFACTURER_NAME) NOT IN ('','UNKNOWN') THEN s.MANUFACTURER_NAME
            ELSE 'UNKNOWN'
        END AS final_product_group,

        CASE
            WHEN s.PRODUCT_FAMILY    IS NOT NULL AND TRIM(s.PRODUCT_FAMILY)    NOT IN ('','UNKNOWN') THEN 'PRODUCT_FAMILY'
            WHEN s.THERAPEUTIC_CLASS IS NOT NULL AND TRIM(s.THERAPEUTIC_CLASS) NOT IN ('','UNKNOWN') THEN 'THERAPEUTIC_CLASS'
            WHEN s.MANUFACTURER_NAME IS NOT NULL AND TRIM(s.MANUFACTURER_NAME) NOT IN ('','UNKNOWN') THEN 'MANUFACTURER_NAME'
            ELSE 'UNKNOWN'
        END AS final_product_group_level,

        s.sap_cust_num_trim,

        COALESCE(
            CASE
                WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN CAST(s.COMMON_GRP_ID AS STRING)
                WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(s.CHAIN_ID AS STRING)
                ELSE CAST(s.COMMON_GRP_ID AS STRING)
            END,
        'NA') AS subset_l2_id_resolved,

        COALESCE(
            CASE
                WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN CAST(s.COMMON_GRP_DESC AS STRING)
                WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(s.CHAIN_DESC AS STRING)
                ELSE CAST(s.COMMON_GRP_DESC AS STRING)
            END,
        'NA') AS subset_l2_desc_resolved,

        CASE
            WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN 'COMMON_GRP_DESC'
            WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN 'CHAIN_DESC'
            ELSE 'COMMON_GRP_DESC'
        END AS subset_l2_desc_source,

        -- SAP key
        CONCAT_WS('|',
            s.MTRL_NUM, s.CUST_SEGMENT, s.ACCT_CLASSIFICATION,
            s.CUST_PROD_CATEGORY, COALESCE(s.sap_cust_num_trim, 'NA')
        ) AS sap_key,

        CONCAT_WS('|',
            CONCAT('MTRL_NME_NVGTON=',      COALESCE(CAST(s.MTRL_NME_NVGTON AS STRING), 'NA')),
            CONCAT('CUST_SEGMENT=',         COALESCE(s.CUST_SEGMENT,        'NA')),
            CONCAT('ACCT_CLASSIFICATION=',  COALESCE(s.ACCT_CLASSIFICATION, 'NA')),
            CONCAT('CUST_PROD_CATEGORY=',   COALESCE(s.CUST_PROD_CATEGORY,  'NA')),
            CONCAT('CUST_NAME=',            COALESCE(s.CUST_NAME,           'NA'))
        ) AS sap_key_desc,

        -- L2 key
        CONCAT_WS('|',
            s.MTRL_NUM, s.CUST_SEGMENT, s.ACCT_CLASSIFICATION, s.CUST_PROD_CATEGORY,
            COALESCE(
                CASE
                    WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN CAST(s.COMMON_GRP_ID AS STRING)
                    WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(s.CHAIN_ID AS STRING)
                    ELSE CAST(s.COMMON_GRP_ID AS STRING)
                END,
            'NA')
        ) AS l2_key,

        CONCAT_WS('|',
            CONCAT('MTRL_NME_NVGTON=',      COALESCE(CAST(s.MTRL_NME_NVGTON AS STRING), 'NA')),
            CONCAT('CUST_SEGMENT=',         COALESCE(s.CUST_SEGMENT,        'NA')),
            CONCAT('ACCT_CLASSIFICATION=',  COALESCE(s.ACCT_CLASSIFICATION, 'NA')),
            CONCAT('CUST_PROD_CATEGORY=',   COALESCE(s.CUST_PROD_CATEGORY,  'NA')),
            CONCAT(
                CASE
                    WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN 'COMMON_GRP_DESC='
                    WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN 'CHAIN_DESC='
                    ELSE 'COMMON_GRP_DESC='
                END,
                COALESCE(CAST(
                    CASE
                        WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN s.COMMON_GRP_DESC
                        WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN s.CHAIN_DESC
                        ELSE s.COMMON_GRP_DESC
                    END
                AS STRING), 'NA')
            )
        ) AS l2_key_desc,

        -- National key
        CONCAT_WS('|',
            s.MTRL_NUM, s.CUST_SEGMENT, s.ACCT_CLASSIFICATION,
            s.CUST_PROD_CATEGORY,
            -- FIX 8: NATIONAL_GRP_ID already cast to STRING in base_layer
            COALESCE(s.NATIONAL_GRP_ID, 'NA')
        ) AS nat_key,

        CONCAT_WS('|',
            CONCAT('MTRL_NME_NVGTON=',    COALESCE(CAST(s.MTRL_NME_NVGTON AS STRING), 'NA')),
            CONCAT('CUST_SEGMENT=',       COALESCE(s.CUST_SEGMENT,        'NA')),
            CONCAT('ACCT_CLASSIFICATION=',COALESCE(s.ACCT_CLASSIFICATION, 'NA')),
            CONCAT('CUST_PROD_CATEGORY=', COALESCE(s.CUST_PROD_CATEGORY,  'NA')),
            CONCAT('NATIONAL_GRP_DESC=',  COALESCE(CAST(s.NATIONAL_GRP_DESC AS STRING), 'NA'))
        ) AS nat_key_desc

    FROM src s
),

/* =========================================================
   Aggregation across normalized rows
   FIX 4: deterministic key fields moved into GROUP BY
   instead of MAX() to make divergence detectable
   ========================================================= */
agg AS (
    SELECT
        n.cal_month_start_dt,
        n.YEAR_MONTH,
        n.CUST_SEGMENT,
        n.ACCT_CLASSIFICATION,
        n.account_class_cd,
        n.CUST_PROD_CATEGORY,
        n.NATIONAL_GRP_ID,
        n.NATIONAL_GRP_DESC,
        n.MTRL_NUM,
        n.sap_cust_num_trim,

        -- Deterministic key fields in GROUP BY (FIX 4)
        n.sap_key,
        n.l2_key,
        n.nat_key,
        n.sap_key_desc,
        n.l2_key_desc,
        n.nat_key_desc,
        n.subset_l2_id_resolved,
        n.subset_l2_desc_resolved,
        n.subset_l2_desc_source,

        -- Non-deterministic descriptor fields — MAX() is appropriate here
        MAX(n.MTRL_NME_NVGTON)          AS MTRL_NME_NVGTON,
        MAX(n.ndc_num)                  AS ndc_num,
        MAX(n.PRODUCT_FAMILY)           AS PRODUCT_FAMILY,
        MAX(n.THERAPEUTIC_CLASS)        AS THERAPEUTIC_CLASS,
        MAX(n.MANUFACTURER_ID)          AS MANUFACTURER_ID,
        MAX(n.MANUFACTURER_NAME)        AS MANUFACTURER_NAME,
        MAX(n.final_product_group)      AS final_product_group,
        MAX(n.final_product_group_level) AS final_product_group_level,
        MAX(n.CUST_NAME)                AS CUST_NAME,
        MAX(n.BRAND_NAME)               AS BRAND_NAME,
        MAX(n.COMMON_GRP_ID)            AS COMMON_GRP_ID,
        MAX(n.COMMON_GRP_DESC)          AS COMMON_GRP_DESC,
        MAX(n.CHAIN_ID)                 AS CHAIN_ID,
        MAX(n.CHAIN_DESC)               AS CHAIN_DESC,
        MAX(n.SUBSET_L2_ID)             AS SUBSET_L2_ID,
        MAX(n.SUBSET_L2_DESC)           AS SUBSET_L2_DESC,
        MAX(n.WAC)                      AS WAC,

        COUNT(*)                        AS contributing_rows,
        SUM(n.TOTAL_NET_COS)            AS TOTAL_NET_COS,
        SUM(n.TOTAL_SLS_QTY)            AS TOTAL_SLS_QTY,
        SUM(n.TOTAL_NET_REVENUE)        AS TOTAL_NET_REVENUE,

        SUM(n.TOTAL_NET_COS)
            / NULLIF(SUM(n.TOTAL_SLS_QTY), 0)
                                        AS contract_price,

        SUM(n.WAC_WEIGHTED * n.TOTAL_SLS_QTY)
            / NULLIF(SUM(CASE WHEN n.WAC_WEIGHTED IS NOT NULL THEN n.TOTAL_SLS_QTY END), 0)
                                        AS wac_weighted,

        (
            SUM(n.TOTAL_NET_COS)
            / NULLIF(SUM(CASE WHEN n.WAC_WEIGHTED IS NOT NULL
                              THEN n.WAC_WEIGHTED * n.TOTAL_SLS_QTY END), 0)
        ) - 1                           AS wac_spread

    FROM normalized n
    GROUP BY
        n.cal_month_start_dt,
        n.YEAR_MONTH,
        n.CUST_SEGMENT,
        n.ACCT_CLASSIFICATION,
        n.account_class_cd,
        n.CUST_PROD_CATEGORY,
        n.NATIONAL_GRP_ID,
        n.NATIONAL_GRP_DESC,
        n.MTRL_NUM,
        n.sap_cust_num_trim,
        n.sap_key,
        n.l2_key,
        n.nat_key,
        n.sap_key_desc,
        n.l2_key_desc,
        n.nat_key_desc,
        n.subset_l2_id_resolved,
        n.subset_l2_desc_resolved,
        n.subset_l2_desc_source
),

/* =========================================================
   Tier assignment
   ========================================================= */
tiered AS (
    SELECT
        a.*,
        sc.sap_months,
        lc.l2_months,
        CASE
            WHEN sc.sap_months >= 6 THEN 'SAP_CUST'
            WHEN lc.l2_months  >= 6 THEN 'L2'
            ELSE 'NATIONAL_GRP_FALLBACK'
        END AS MODEL_TIER,
        CASE
            WHEN sc.sap_months >= 6 THEN a.sap_key
            WHEN lc.l2_months  >= 6 THEN a.l2_key
            ELSE                         a.nat_key
        END AS HYBRID_MODEL_KEY_3T,
        CASE
            WHEN sc.sap_months >= 6 THEN a.sap_key_desc
            WHEN lc.l2_months  >= 6 THEN a.l2_key_desc
            ELSE                         a.nat_key_desc
        END AS HYBRID_MODEL_KEY_3T_DESC
    FROM agg a
    LEFT JOIN sap_coverage sc ON sc.sap_key = a.sap_key
    LEFT JOIN l2_coverage  lc ON lc.l2_key  = a.l2_key
),

/* =========================================================
   Quality flags
   ========================================================= */
flagged AS (
    SELECT
        t.*,
        CASE WHEN contract_price < 0                                THEN 1 ELSE 0 END AS negative_contract_price_flag,
        CASE WHEN TOTAL_SLS_QTY  < 3                                THEN 1 ELSE 0 END AS low_qty_flag,
        CASE WHEN ABS(TOTAL_NET_COS) < 1                            THEN 1 ELSE 0 END AS low_ncos_flag,
        CASE WHEN wac_weighted IS NULL OR wac_weighted <= 0         THEN 1 ELSE 0 END AS invalid_wac_flag,

        CASE
            WHEN acct_classification IN ('WAC','340B-CP','340B-CE') THEN 0
            WHEN wac_weighted IS NULL OR wac_weighted <= 0          THEN 0
            WHEN contract_price > wac_weighted * 1.05               THEN 1
            ELSE 0
        END AS contract_price_above_wac_flag,

        CASE
            WHEN contract_price IS NULL                             THEN 1
            WHEN TOTAL_SLS_QTY = 0                                  THEN 1
            WHEN ABS(TOTAL_NET_COS) < 1                             THEN 1
            WHEN contract_price < 0                                 THEN 1
            WHEN acct_classification IN ('WAC','340B-CP','340B-CE') THEN 0
            WHEN wac_weighted IS NOT NULL AND wac_weighted > 0
             AND contract_price > wac_weighted * 1.50               THEN 1
            WHEN wac_weighted IS NOT NULL AND wac_weighted > 0
             AND contract_price < wac_weighted * 0.01               THEN 1
            WHEN wac_weighted IS NOT NULL AND wac_weighted > 0
             AND contract_price > wac_weighted * 1.05               THEN 1
            ELSE 0
        END AS exclude_from_training_flag
    FROM tiered t
),

/* =========================================================
   Series statistics
   FIX 4 (MEDIAN): MEDIAN() not supported as window function
   in Databricks — replaced with PERCENTILE(expr, 0.5) OVER()
   ========================================================= */
series_stats AS (
    SELECT
        f.*,
        HYBRID_MODEL_KEY_3T AS groupby_key,

        PERCENTILE(
            CASE WHEN exclude_from_training_flag = 0 THEN contract_price END,
            0.5
        ) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, MTRL_NUM
        ) AS median_contract_price,

        STDDEV_SAMP(
            CASE WHEN exclude_from_training_flag = 0 THEN contract_price END
        ) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, MTRL_NUM
        ) AS stddev_contract_price,

        COUNT(
            CASE WHEN exclude_from_training_flag = 0 THEN 1 END
        ) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, MTRL_NUM
        ) AS valid_time_series_points

    FROM flagged f
),

/* =========================================================
   Outlier flagging
   FIX 7: avg contract price computed here as window aggregates
   to avoid double-scanning outlier_flagged in a separate CTE
   ========================================================= */
outlier_flagged AS (
    SELECT
        s.*,

        CASE
            WHEN exclude_from_training_flag = 1        THEN 0
            WHEN valid_time_series_points   < 3        THEN 0
            WHEN stddev_contract_price IS NULL         THEN 0
            WHEN stddev_contract_price = 0             THEN 0
            WHEN ABS(contract_price - median_contract_price)
                 > 2 * stddev_contract_price           THEN 1
            ELSE 0
        END AS contract_price_outlier_flag,

        CASE
            WHEN exclude_from_training_flag = 0
             AND (
                    valid_time_series_points < 6
                 OR stddev_contract_price IS NULL
                 OR stddev_contract_price = 0
                 OR ABS(contract_price - median_contract_price)
                    <= 3 * stddev_contract_price
                 )
                THEN 1
            ELSE 0
        END AS include_in_avg_contract_price_flag

    FROM series_stats s
),

/* =========================================================
   Average contract price — FIX 7: computed as window
   aggregates directly on outlier_flagged to avoid a
   second full scan of that CTE via a separate GROUP BY CTE
   ========================================================= */
avg_stats AS (
    SELECT
        o.*,

        -- Simple average (excluding outliers)
        AVG(CASE WHEN include_in_avg_contract_price_flag = 1 THEN contract_price END)
            OVER (PARTITION BY groupby_key, MTRL_NUM)
            AS avg_contract_price_excl_outliers,

        -- Quantity-weighted average (excluding outliers)
        SUM(CASE WHEN include_in_avg_contract_price_flag = 1 THEN TOTAL_NET_COS END)
            OVER (PARTITION BY groupby_key, MTRL_NUM)
        / NULLIF(
            SUM(CASE WHEN include_in_avg_contract_price_flag = 1 THEN TOTAL_SLS_QTY END)
                OVER (PARTITION BY groupby_key, MTRL_NUM),
          0)
            AS qty_weighted_avg_contract_price_excl_outliers,

        -- Month counts
        COUNT(CASE WHEN include_in_avg_contract_price_flag = 1 THEN 1 END)
            OVER (PARTITION BY groupby_key, MTRL_NUM)
            AS months_used_in_avg_contract_price,

        COUNT(CASE WHEN contract_price_outlier_flag = 1 THEN 1 END)
            OVER (PARTITION BY groupby_key, MTRL_NUM)
            AS months_excluded_as_contract_price_outliers

    FROM outlier_flagged o
),

/* =========================================================
   MoM lag extraction — FIX 6: LAG() computed once here,
   referenced by alias below to avoid repeating window specs
   ========================================================= */
mom_lagged AS (
    SELECT
        a.*,
        LAG(contract_price) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, MTRL_NUM
            ORDER BY cal_month_start_dt
        ) AS prev_cp,
        LAG(wac_weighted) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, MTRL_NUM
            ORDER BY cal_month_start_dt
        ) AS prev_wac
    FROM avg_stats a
),

/* =========================================================
   MoM price movement flags — references prev_cp / prev_wac
   aliases from mom_lagged rather than repeating LAG() calls
   ========================================================= */
mom_flags AS (
    SELECT
        m.*,
        prev_cp                                             AS prev_month_contract_price,
        prev_wac                                            AS prev_month_wac_weighted,

        (contract_price - prev_cp)
            / NULLIF(prev_cp, 0)                            AS contract_price_mom_pct_change,

        CASE
            WHEN prev_cp IS NULL                                            THEN NULL
            WHEN (contract_price - prev_cp) / NULLIF(prev_cp, 0) <= -0.30  THEN 1
            ELSE 0
        END AS contract_price_drop_30pct_flag,

        CASE
            WHEN prev_cp IS NULL                                            THEN NULL
            WHEN (contract_price - prev_cp) / NULLIF(prev_cp, 0) >= 0.30   THEN 1
            ELSE 0
        END AS contract_price_inc_30pct_flag,

        CASE
            WHEN prev_cp IS NULL          THEN NULL
            WHEN contract_price > prev_cp THEN 'INCREASE'
            WHEN contract_price < prev_cp THEN 'DECREASE'
            ELSE 'FLAT'
        END AS contract_price_mom_direction,

        CASE
            WHEN prev_wac IS NULL        THEN NULL
            WHEN wac_weighted < prev_wac THEN 1
            ELSE 0
        END AS wac_mom_decrease_flag,

        (wac_weighted - prev_wac)
            / NULLIF(prev_wac, 0)                           AS wac_mom_pct_change

    FROM mom_lagged m
)

/* =========================================================
   Final output — wac_5pct_drop_flag computed inline
   since it only needs wac_mom_pct_change
   ========================================================= */
SELECT
    m.*,
    CASE
        WHEN wac_mom_pct_change IS NULL   THEN NULL
        WHEN wac_mom_pct_change <= -0.05  THEN 1
        ELSE 0
    END AS wac_5pct_drop_flag
FROM mom_flags m
;