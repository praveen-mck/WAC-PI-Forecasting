SELECT
    t_copa.MTRL_NUM,
    mtrl.MTRL_NME_NVGTON,

    cust.COMMON_GRP_ID,
    cust.COMMON_GRP_NAME AS COMMON_GRP_DESC,

    cust.ACCT_CHN_ID AS CHAIN_ID,
    cust.ACCT_CHN_NAME AS CHAIN_DESC,

    cust.NATL_GRP_CD AS NATIONAL_GRP_ID,
    cust.NATL_GRP_NAM AS NATIONAL_GRP_DESC,

    CASE
        WHEN t_copa.FPA_CUST_SEG_CD IN ('A', 'B') THEN 'CP&H'
        WHEN t_copa.FPA_CUST_SEG_CD IN ('C', 'D', 'W') THEN 'SNA'
        WHEN t_copa.FPA_CUST_SEG_CD IN ('F', 'H') THEN 'MHS'
        ELSE 'INTERCO'
    END AS CUST_SEGMENT,

    CASE
        WHEN cust.ACCT_CLAS_CD = '2' THEN 'GPO'
        WHEN cust.ACCT_CLAS_CD = '4' THEN '340B-CE'
        WHEN cust.ACCT_CLAS_CD = '5' THEN '340B-CP'
        ELSE 'WAC'
    END AS ACCT_CLASSIFICATION,

    CASE
        WHEN t_copa.BILL_TYPE_CD IN ('ZPD1', 'ZPD5', 'ZPDS', 'ZPF2', 'ZPS1', 'ZPS3', 'ZPS6', 'ZPS7')
            THEN 'Invoice'
        WHEN t_copa.BILL_TYPE_CD IN ('ZAB', 'ZDD2', 'ZPA', 'ZPD2', 'ZPD3', 'ZPDM')
            THEN 'Debit'
        WHEN t_copa.BILL_TYPE_CD IN (
            'ZAX', 'ZCPA', 'ZDC2', 'ZPC', 'ZPC1', 'ZPC2', 'ZPC3', 'ZPCR', 'ZPS2', 'ZPS5', 'ZTC2'
        )
            THEN 'Credit'
        ELSE 'Other'
    END AS BILL_TYPE,

    CASE
        WHEN t_copa.CMPNY_CD = '8545' THEN
            CASE
                WHEN t_copa.PROD_HIER_1_NUM = '85451' THEN 'MPB Plasma'
                ELSE 'MPB Specialty'
            END
        WHEN t_copa.PROD_HIER_1_NUM IN ('00030', '00050')
             AND t_copa.SLS_CTGRY_CD NOT IN ('200', '250', '300', '400', '410', '500', '510')
            THEN 'OTC'
        WHEN t_copa.PROD_HIER_1_NUM = '00020'
             AND t_copa.CMPNY_CD <> '8545'
            THEN 'GX'
        WHEN t_copa.SLS_CTGRY_CD IN (
            '102', '103', '106', '107', '112', '116', '122', '123',
            '701', '703', '711', '806', '807', '816'
        )
            THEN 'DROP SHIP'
        WHEN t_copa.MTRL_GRP2_CD = 'W2' THEN 'GLP-1'
        WHEN t_copa.MTRL_GRP2_CD IN ('R1', 'R2') THEN 'BIOSIMS'
        WHEN t_copa.MTRL_GRP2_CD IN ('V1', 'V2') THEN 'VAX'
        WHEN t_copa.MTRL_GRP2_CD IN ('S1', 'S3', 'S4', 'S5', 'S6') THEN 'APOLLO'
        ELSE 'BX'
    END AS CUST_PROD_CATEGORY,

    SUM(t_copa.NET_COS) / NULLIF(SUM(t_copa.SLS_QTY_BEX), 0) AS CONTRACT_PRICE,
    SUM(t_copa.NET_COS) AS TOTAL_NET_COS,
    SUM(t_copa.SLS_QTY_BEX) AS TOTAL_SLS_QTY

FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa t_copa

LEFT JOIN fdp_prod.psas_fdp_all_gold.vw_q_material_pharma_bw mtrl
    ON t_copa.MTRL_NUM = mtrl.MATERIAL
   AND mtrl.CURR_FLG = 'Y'

LEFT JOIN uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr cust
    ON CAST(cust.CUST_ACCT_ID AS STRING) = RIGHT(CAST(t_copa.SAP_CUST_NUM AS STRING), 6)
   AND cust.ACTIVE_CUST_IND = 'A'

WHERE
    t_copa.POST_DT BETWEEN '2025-01-01' AND '2025-12-31'
    AND t_copa.CMPNY_CD IN ('8000', '8545')
    AND t_copa.BUS_TYPE_CD NOT IN ('18', '19', '20')
    AND t_copa.SLS_QTY_BEX > 0
    AND (
        CASE
            WHEN t_copa.FPA_CUST_SEG_CD IN ('A', 'B') THEN 'CP&H'
            WHEN t_copa.FPA_CUST_SEG_CD IN ('C', 'D', 'W') THEN 'SNA'
            WHEN t_copa.FPA_CUST_SEG_CD IN ('F', 'H') THEN 'MHS'
            ELSE 'INTERCO'
        END
    ) <> 'INTERCO'

GROUP BY ALL;
