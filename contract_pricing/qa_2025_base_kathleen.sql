/* =========================================================
Q1 vs vw_q_contract_price_base_2025 reconciliation
Aligned logic:
- 2025 only
- CUST_ACCT_ID join
- ACTIVE_CUST_IND = 'A'
- SLS_QTY_BEX > 0
- INTERCO excluded
- bill type from CASE logic
========================================================= */

WITH q1_detail AS (
    SELECT
        DATE_FORMAT(t_copa.POST_DT, 'yyyy-MM') AS YEAR_MONTH,

        /* standardize material id to match Q2 */
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(t_copa.MTRL_NUM AS STRING), '^0+', ''), ''), '0'),
            18,
            '0'
        ) AS MTRL_NUM,

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
                '102', '103', '106', '107', '112', '116',
                '122', '123', '701', '703', '711', '806', '807', '816'
            )
                THEN 'DROP SHIP'
            WHEN t_copa.MTRL_GRP2_CD = 'W2' THEN 'GLP-1'
            WHEN t_copa.MTRL_GRP2_CD IN ('R1', 'R2') THEN 'BIOSIMS'
            WHEN t_copa.MTRL_GRP2_CD IN ('V1', 'V2') THEN 'VAX'
            WHEN t_copa.MTRL_GRP2_CD IN ('S1', 'S3', 'S4', 'S5', 'S6') THEN 'APOLLO'
            ELSE 'BX'
        END AS CUST_PROD_CATEGORY,

        SUM(t_copa.NET_COS) AS TOTAL_NET_COS,
        SUM(t_copa.SLS_QTY_BEX) AS TOTAL_SLS_QTY

    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa t_copa

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

    GROUP BY
        DATE_FORMAT(t_copa.POST_DT, 'yyyy-MM'),
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(t_copa.MTRL_NUM AS STRING), '^0+', ''), ''), '0'),
            18,
            '0'
        ),
        CASE
            WHEN t_copa.FPA_CUST_SEG_CD IN ('A', 'B') THEN 'CP&H'
            WHEN t_copa.FPA_CUST_SEG_CD IN ('C', 'D', 'W') THEN 'SNA'
            WHEN t_copa.FPA_CUST_SEG_CD IN ('F', 'H') THEN 'MHS'
            ELSE 'INTERCO'
        END,
        CASE
            WHEN cust.ACCT_CLAS_CD = '2' THEN 'GPO'
            WHEN cust.ACCT_CLAS_CD = '4' THEN '340B-CE'
            WHEN cust.ACCT_CLAS_CD = '5' THEN '340B-CP'
            ELSE 'WAC'
        END,
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
        END,
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
                '102', '103', '106', '107', '112', '116',
                '122', '123', '701', '703', '711', '806', '807', '816'
            )
                THEN 'DROP SHIP'
            WHEN t_copa.MTRL_GRP2_CD = 'W2' THEN 'GLP-1'
            WHEN t_copa.MTRL_GRP2_CD IN ('R1', 'R2') THEN 'BIOSIMS'
            WHEN t_copa.MTRL_GRP2_CD IN ('V1', 'V2') THEN 'VAX'
            WHEN t_copa.MTRL_GRP2_CD IN ('S1', 'S3', 'S4', 'S5', 'S6') THEN 'APOLLO'
            ELSE 'BX'
        END
),

q2_detail AS (
    SELECT
        YEAR_MONTH,
        MTRL_NUM,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        BILL_TYPE,
        CUST_PROD_CATEGORY,
        SUM(TOTAL_NET_COS) AS TOTAL_NET_COS,
        SUM(TOTAL_SLS_QTY) AS TOTAL_SLS_QTY
    FROM uspd_analytics_den.analytics_gold.vw_q_contract_price_base_2025
    GROUP BY
        YEAR_MONTH,
        MTRL_NUM,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        BILL_TYPE,
        CUST_PROD_CATEGORY
),

/* =========================================================
1) OVERALL TOTAL
========================================================= */
overall_q1 AS (
    SELECT
        'TOTAL' AS RECON_LEVEL,
        'ALL' AS RECON_KEY,
        SUM(TOTAL_NET_COS) AS Q1_NET_COS,
        SUM(TOTAL_SLS_QTY) AS Q1_SLS_QTY
    FROM q1_detail
),

overall_q2 AS (
    SELECT
        'TOTAL' AS RECON_LEVEL,
        'ALL' AS RECON_KEY,
        SUM(TOTAL_NET_COS) AS Q2_NET_COS,
        SUM(TOTAL_SLS_QTY) AS Q2_SLS_QTY
    FROM q2_detail
),

/* =========================================================
2) BILL TYPE LEVEL
========================================================= */
billtype_q1 AS (
    SELECT
        'BILL_TYPE' AS RECON_LEVEL,
        BILL_TYPE AS RECON_KEY,
        SUM(TOTAL_NET_COS) AS Q1_NET_COS,
        SUM(TOTAL_SLS_QTY) AS Q1_SLS_QTY
    FROM q1_detail
    GROUP BY BILL_TYPE
),

billtype_q2 AS (
    SELECT
        'BILL_TYPE' AS RECON_LEVEL,
        BILL_TYPE AS RECON_KEY,
        SUM(TOTAL_NET_COS) AS Q2_NET_COS,
        SUM(TOTAL_SLS_QTY) AS Q2_SLS_QTY
    FROM q2_detail
    GROUP BY BILL_TYPE
),

/* =========================================================
3) MATERIAL + SEGMENT + BILL TYPE + ACCT CLASS + PROD CAT
Best root-cause grain
========================================================= */
grain_q1 AS (
    SELECT
        'DETAIL' AS RECON_LEVEL,
        CONCAT_WS(
            ' | ',
            YEAR_MONTH,
            MTRL_NUM,
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            BILL_TYPE,
            CUST_PROD_CATEGORY
        ) AS RECON_KEY,
        SUM(TOTAL_NET_COS) AS Q1_NET_COS,
        SUM(TOTAL_SLS_QTY) AS Q1_SLS_QTY
    FROM q1_detail
    GROUP BY
        YEAR_MONTH,
        MTRL_NUM,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        BILL_TYPE,
        CUST_PROD_CATEGORY
),

grain_q2 AS (
    SELECT
        'DETAIL' AS RECON_LEVEL,
        CONCAT_WS(
            ' | ',
            YEAR_MONTH,
            MTRL_NUM,
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            BILL_TYPE,
            CUST_PROD_CATEGORY
        ) AS RECON_KEY,
        SUM(TOTAL_NET_COS) AS Q2_NET_COS,
        SUM(TOTAL_SLS_QTY) AS Q2_SLS_QTY
    FROM q2_detail
    GROUP BY
        YEAR_MONTH,
        MTRL_NUM,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        BILL_TYPE,
        CUST_PROD_CATEGORY
),

/* =========================================================
UNION ALL ALL RECON VIEWS
========================================================= */
recon AS (
    SELECT
        o1.RECON_LEVEL,
        o1.RECON_KEY,
        o1.Q1_NET_COS,
        o2.Q2_NET_COS,
        o1.Q1_SLS_QTY,
        o2.Q2_SLS_QTY
    FROM overall_q1 o1
    FULL OUTER JOIN overall_q2 o2
        ON o1.RECON_LEVEL = o2.RECON_LEVEL
       AND o1.RECON_KEY = o2.RECON_KEY

    UNION ALL

    SELECT
        b1.RECON_LEVEL,
        b1.RECON_KEY,
        b1.Q1_NET_COS,
        b2.Q2_NET_COS,
        b1.Q1_SLS_QTY,
        b2.Q2_SLS_QTY
    FROM billtype_q1 b1
    FULL OUTER JOIN billtype_q2 b2
        ON b1.RECON_LEVEL = b2.RECON_LEVEL
       AND b1.RECON_KEY = b2.RECON_KEY

    UNION ALL

    SELECT
        g1.RECON_LEVEL,
        g1.RECON_KEY,
        g1.Q1_NET_COS,
        g2.Q2_NET_COS,
        g1.Q1_SLS_QTY,
        g2.Q2_SLS_QTY
    FROM grain_q1 g1
    FULL OUTER JOIN grain_q2 g2
        ON g1.RECON_LEVEL = g2.RECON_LEVEL
       AND g1.RECON_KEY = g2.RECON_KEY
)

SELECT
    RECON_LEVEL,
    RECON_KEY,

    Q1_NET_COS,
    Q2_NET_COS,
    COALESCE(Q1_NET_COS, 0) - COALESCE(Q2_NET_COS, 0) AS NET_COS_DIFF,

    Q1_SLS_QTY,
    Q2_SLS_QTY,
    COALESCE(Q1_SLS_QTY, 0) - COALESCE(Q2_SLS_QTY, 0) AS SLS_QTY_DIFF,

    COALESCE(Q1_NET_COS, 0) / NULLIF(COALESCE(Q1_SLS_QTY, 0), 0) AS Q1_CONTRACT_PRICE,
    COALESCE(Q2_NET_COS, 0) / NULLIF(COALESCE(Q2_SLS_QTY, 0), 0) AS Q2_CONTRACT_PRICE,
    (
        COALESCE(Q1_NET_COS, 0) / NULLIF(COALESCE(Q1_SLS_QTY, 0), 0)
        -
        COALESCE(Q2_NET_COS, 0) / NULLIF(COALESCE(Q2_SLS_QTY, 0), 0)
    ) AS CONTRACT_PRICE_DIFF

FROM recon
WHERE
    COALESCE(Q1_NET_COS, 0) <> COALESCE(Q2_NET_COS, 0)
    OR COALESCE(Q1_SLS_QTY, 0) <> COALESCE(Q2_SLS_QTY, 0)

ORDER BY
    CASE RECON_LEVEL
        WHEN 'TOTAL' THEN 1
        WHEN 'BILL_TYPE' THEN 2
        WHEN 'DETAIL' THEN 3
        ELSE 99
    END,
    ABS(COALESCE(Q1_NET_COS, 0) - COALESCE(Q2_NET_COS, 0)) DESC,
    ABS(COALESCE(Q1_SLS_QTY, 0) - COALESCE(Q2_SLS_QTY, 0)) DESC;
