CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.vw_q_contract_price_base AS

SELECT
        DATE_FORMAT(t_copa.POST_DT, 'yyyy-MM') AS YEAR_MONTH,

        t_copa.MTRL_NUM,
        mtrl.MTRL_NME_NVGTON,

        /* Customer hierarchy */
        cust_mstr.COMMON_GRP_ID,
        cust_mstr.COMMON_GRP_NAME AS COMMON_GRP_DESC,
        cust_mstr.CUST_CHN_ID AS CHAIN_ID,
        cust_mstr.CUST_CHN_NAME AS CHAIN_DESC,
        cust_mstr.NATL_GRP_CD AS NATIONAL_GRP_ID,
        cust_mstr.NATL_GRP_NAM AS NATIONAL_GRP_DESC,

        /* Segment */
        CASE
            WHEN t_copa.FPA_CUST_SEG_CD IN ('A', 'B') THEN 'CP&H'
            WHEN t_copa.FPA_CUST_SEG_CD IN ('C', 'D', 'W') THEN 'SNA'
            WHEN t_copa.FPA_CUST_SEG_CD IN ('F', 'H') THEN 'MHS'
            ELSE 'INTERCO'
        END AS CUST_SEGMENT,

        /* Account classification */
        CASE
            WHEN cust_mstr.ACCT_CLAS_CD IN ('2') THEN 'GPO'
            WHEN cust_mstr.ACCT_CLAS_CD IN ('4') THEN '340B-CE'
            WHEN cust_mstr.ACCT_CLAS_CD IN ('5') THEN '340B-CP'
            ELSE 'WAC'
        END AS ACCT_CLASSIFICATION,

        /* FORCE BILL TYPE = Invoice */
        'Invoice' AS BILL_TYPE,

        /* Product category */
        CASE
            WHEN t_copa.CMPNY_CD = '8545' THEN
                CASE
                    WHEN t_copa.PROD_HIER_1_NUM = '85451' THEN 'MPB Plasma'
                    ELSE 'MPB Specialty'
                END
            WHEN t_copa.PROD_HIER_1_NUM IN ('00030', '00050')
                 AND t_copa.SLS_CTGRY_CD NOT IN ('200','250','300','400','410','500','510')
                THEN 'OTC'
            WHEN t_copa.PROD_HIER_1_NUM = '00020'
                 AND t_copa.CMPNY_CD <> '8545'
                THEN 'GX'
            WHEN t_copa.SLS_CTGRY_CD IN (
                '102','103','106','107','112','116',
                '122','123','701','703','711','806','807','816'
            )
                THEN 'DROP SHIP'
            WHEN t_copa.MTRL_GRP2_CD = 'W2' THEN 'GLP-1'
            WHEN t_copa.MTRL_GRP2_CD IN ('R1','R2') THEN 'BIOSIMS'
            WHEN t_copa.MTRL_GRP2_CD IN ('V1','V2') THEN 'VAX'
            WHEN t_copa.MTRL_GRP2_CD IN ('S1','S3','S4','S5','S6') THEN 'APOLLO'
            ELSE 'BX'
        END AS CUST_PROD_CATEGORY,

        sum(t_copa.NET_COS) AS TOTAL_NET_COS,
        sum(t_copa.SLS_QTY_BEX) AS TOTAL_SLS_QTY_BEX,
        avg(t_copa.WAC) AS AVG_WAC

    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa t_copa

    LEFT JOIN fdp_prod.psas_fdp_all_gold.vw_q_material_pharma_bw mtrl
        ON t_copa.MTRL_NUM = mtrl.MATERIAL
       AND mtrl.CURR_FLG = 'Y'

    LEFT JOIN uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr cust_mstr
        ON CAST(cust_mstr.CUST_ACCT_ID AS STRING) = RIGHT(CAST(t_copa.SAP_CUST_NUM AS STRING), 6)

    WHERE t_copa.POST_DT BETWEEN '2022-01-01' AND '2026-05-31'
      AND t_copa.CMPNY_CD IN ('8000', '8545')
      AND t_copa.BUS_TYPE_CD NOT IN ('18', '19', '20')
      AND t_copa.SLS_QTY_BEX > 0

   
      /* only invoice SAP bill types */
      AND t_copa.BILL_TYPE_CD IN ('ZPD1', 'ZPD5', 'ZPDS', 'ZPF2', 'ZPS1', 'ZPS3', 'ZPS6', 'ZPS7')
            GROUP BY
    YEAR_MONTH,
    CUST_SEGMENT,
    CUST_PROD_CATEGORY,
    MTRL_NUM,
    MTRL_NME_NVGTON,
    cust_mstr.COMMON_GRP_ID,
    COMMON_GRP_DESC,
    CHAIN_ID,
    CHAIN_DESC,
    NATIONAL_GRP_ID,
    NATIONAL_GRP_DESC, cust_mstr.ACCT_CLAS_CD;

    select * from uspd_analytics_den.analytics_gold.vw_q_contract_price_base;

    
