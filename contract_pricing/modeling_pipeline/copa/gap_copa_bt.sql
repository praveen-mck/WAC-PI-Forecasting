-- Categorize why each COPA-only series has no BT forecast
WITH

run_ranges AS (
    SELECT 'BT_2025_01'          AS run_id,
           TO_DATE('2025-01-01') AS start_dt,
           TO_DATE('2026-12-31') AS end_dt
),

copa_grain AS (
    SELECT
        LPAD(RIGHT(CAST(c.sap_cust_num AS STRING), 6), 6, '0')      AS sap_cust_num_trim,
        REGEXP_REPLACE(CAST(c.mtrl_num AS STRING), '^0+', '')        AS mtrl_num,
        CAST(DATE_TRUNC('month', c.post_dt) AS DATE)                 AS cal_month,
        CASE
            WHEN c.fpa_cust_seg_cd IN ('A','B')     THEN 'CP&H'
            WHEN c.fpa_cust_seg_cd IN ('C','D','W') THEN 'SNA'
            WHEN c.fpa_cust_seg_cd IN ('F','H')     THEN 'MHS'
            ELSE 'INTERCO'
        END                                                          AS cust_segment,
        CASE
            WHEN c.cmpny_cd = '8545' THEN
                CASE WHEN c.prod_hier_1_num = '85451' THEN 'MPB Plasma' ELSE 'MPB Specialty' END
            WHEN c.prod_hier_1_num IN ('00030','00050')
             AND c.sls_ctgry_cd NOT IN ('200','250','300','400','410','500','510') THEN 'OTC'
            WHEN c.prod_hier_1_num = '00020'
             AND c.cmpny_cd <> '8545'                                THEN 'GX'
            WHEN c.sls_ctgry_cd IN (
                '102','103','106','107','112','116',
                '122','123','701','703','711','806','807','816'
            )                                                        THEN 'DROP SHIP'
            WHEN c.mtrl_grp2_cd = 'W2'                              THEN 'GLP-1'
            WHEN c.mtrl_grp2_cd IN ('R1','R2')                      THEN 'BIOSIMS'
            WHEN c.mtrl_grp2_cd IN ('V1','V2')                      THEN 'VAX'
            WHEN c.mtrl_grp2_cd IN ('S1','S3','S4','S5','S6')       THEN 'APOLLO'
            ELSE 'BX'
        END                                                          AS cust_prod_category,
        SUM(c.sls_qty_bex)                                           AS copa_sls_qty,
        SUM(c.net_cos)                                               AS copa_net_cos,
        MAX(c.bill_type_cd)                                          AS bill_type_cd,
        MAX(CASE WHEN c.sls_qty_bex > 0 AND c.net_cos > 0 THEN 1 ELSE 0 END)
                                                                     AS has_valid_txn
    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa c
    CROSS JOIN run_ranges rr
    WHERE c.post_dt BETWEEN rr.start_dt AND rr.end_dt
      AND c.cmpny_cd IN ('8000','8545')
      AND c.bus_type_cd NOT IN ('18','19','20')
      AND c.fpa_cust_seg_cd IN ('A','B','C','D','W','F','H')
      AND RIGHT(CAST(c.sap_cust_num AS STRING), 6) IN (
          SELECT CAST(cust_acct_id AS STRING)
          FROM uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr
          WHERE active_cust_ind = 'A'
      )
    GROUP BY 1, 2, 3, 4, 5
),

-- All unique cust+material+segment+prodcat in BT
bt_series AS (
    SELECT DISTINCT
        LPAD(CAST(sap_cust_num_trim AS STRING), 6, '0')              AS sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')           AS mtrl_num,
        cust_segment,
        cust_prod_category
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v21
    WHERE run_id = 'BT_2025_01'
),

-- Also check modeling base to understand filter reasons
modeling_base_series AS (
    SELECT DISTINCT
        sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')           AS mtrl_num,
        cust_segment,
        cust_prod_category
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21
),

copa_series AS (
    SELECT
        sap_cust_num_trim,
        mtrl_num,
        cust_segment,
        cust_prod_category,
        MAX(has_valid_txn)          AS has_valid_txn,
        SUM(copa_sls_qty)           AS total_copa_sls_qty,
        SUM(copa_net_cos)           AS total_copa_net_cos,
        COUNT(DISTINCT cal_month)   AS copa_months
    FROM copa_grain
    GROUP BY 1, 2, 3, 4
),

diagnosed AS (
    SELECT
        c.*,
        CASE WHEN bt.sap_cust_num_trim IS NOT NULL THEN 1 ELSE 0 END  AS in_bt,
        CASE WHEN mb.sap_cust_num_trim IS NOT NULL THEN 1 ELSE 0 END  AS in_modeling_base,

        -- Classify why the series is missing from BT
        CASE
            WHEN bt.sap_cust_num_trim IS NOT NULL
                THEN 'MATCHED'
            WHEN c.has_valid_txn = 0
                THEN 'NO_VALID_TXNS_NULL_OR_NEG'        -- filtered out by sls_qty/net_cos guards
            WHEN mb.sap_cust_num_trim IS NULL
                THEN 'NOT_IN_MODELING_BASE'             -- never made it into the model pipeline
            WHEN c.copa_months < 3
                THEN 'TOO_FEW_MONTHS_FOR_MODEL'         -- insufficient history to model
            ELSE 'IN_MODELING_BASE_NOT_IN_BT'           -- made it to base but filtered/excluded before BT
        END                                             AS missing_reason

    FROM copa_series c
    LEFT JOIN bt_series bt
        ON  c.sap_cust_num_trim  = bt.sap_cust_num_trim
        AND c.mtrl_num           = bt.mtrl_num
        AND c.cust_segment       = bt.cust_segment
        AND c.cust_prod_category = bt.cust_prod_category
    LEFT JOIN modeling_base_series mb
        ON  c.sap_cust_num_trim  = mb.sap_cust_num_trim
        AND c.mtrl_num           = mb.mtrl_num
        AND c.cust_segment       = mb.cust_segment
        AND c.cust_prod_category = mb.cust_prod_category
)

SELECT
    missing_reason,
    COUNT(*)                                            AS series_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total,
    SUM(total_copa_net_cos)                             AS total_copa_net_cos,
    ROUND(100.0 * SUM(total_copa_net_cos)
        / SUM(SUM(total_copa_net_cos)) OVER (), 2)      AS pct_of_total_dollars,
    AVG(copa_months)                                    AS avg_copa_months,
    AVG(total_copa_net_cos)                             AS avg_net_cos_per_series
FROM diagnosed
GROUP BY missing_reason
ORDER BY series_count DESC;

SELECT
    exclude_from_actuals_flag,
    exclude_from_training_flag,
    regime_change_type,
    zombie_sale_flag,
    contract_price_above_wac_flag,
    invalid_wac_flag,
    COUNT(DISTINCT sap_cust_num_trim || '|' || mtrl_num
          || '|' || cust_segment || '|' || cust_prod_category) AS series_count,
    SUM(total_net_cos)                                          AS total_net_cos
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21
WHERE (sap_cust_num_trim || '|' ||
       REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '') || '|' ||
       cust_segment || '|' || cust_prod_category)
    IN (
        -- The IN_MODELING_BASE_NOT_IN_BT series from your COPA diagnostic
        SELECT c.sap_cust_num_trim || '|' || c.mtrl_num || '|' ||
               c.cust_segment || '|' || c.cust_prod_category
        FROM (
            SELECT DISTINCT
                LPAD(RIGHT(CAST(sap_cust_num AS STRING), 6), 6, '0')    AS sap_cust_num_trim,
                REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')      AS mtrl_num,
                CASE
                    WHEN fpa_cust_seg_cd IN ('A','B')     THEN 'CP&H'
                    WHEN fpa_cust_seg_cd IN ('C','D','W') THEN 'SNA'
                    WHEN fpa_cust_seg_cd IN ('F','H')     THEN 'MHS'
                    ELSE 'INTERCO'
                END                                                      AS cust_segment,
                CASE
                    WHEN cmpny_cd = '8545' THEN
                        CASE WHEN prod_hier_1_num = '85451' THEN 'MPB Plasma' ELSE 'MPB Specialty' END
                    WHEN prod_hier_1_num IN ('00030','00050')
                     AND sls_ctgry_cd NOT IN ('200','250','300','400','410','500','510') THEN 'OTC'
                    WHEN prod_hier_1_num = '00020'
                     AND cmpny_cd <> '8545'                              THEN 'GX'
                    WHEN sls_ctgry_cd IN (
                        '102','103','106','107','112','116',
                        '122','123','701','703','711','806','807','816'
                    )                                                    THEN 'DROP SHIP'
                    WHEN mtrl_grp2_cd = 'W2'                            THEN 'GLP-1'
                    WHEN mtrl_grp2_cd IN ('R1','R2')                    THEN 'BIOSIMS'
                    WHEN mtrl_grp2_cd IN ('V1','V2')                    THEN 'VAX'
                    WHEN mtrl_grp2_cd IN ('S1','S3','S4','S5','S6')     THEN 'APOLLO'
                    ELSE 'BX'
                END                                                      AS cust_prod_category
            FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa
            WHERE post_dt BETWEEN '2025-01-01' AND '2026-12-31'
              AND cmpny_cd IN ('8000','8545')
              AND bus_type_cd NOT IN ('18','19','20')
              AND fpa_cust_seg_cd IN ('A','B','C','D','W','F','H')
        ) c
        LEFT JOIN (
            SELECT DISTINCT
                LPAD(CAST(sap_cust_num_trim AS STRING), 6, '0')          AS sap_cust_num_trim,
                REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')       AS mtrl_num,
                cust_segment,
                cust_prod_category
            FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v21
            WHERE run_id = 'BT_2025_01'
        ) bt
            ON  c.sap_cust_num_trim  = bt.sap_cust_num_trim
            AND c.mtrl_num           = bt.mtrl_num
            AND c.cust_segment       = bt.cust_segment
            AND c.cust_prod_category = bt.cust_prod_category
        WHERE bt.sap_cust_num_trim IS NULL
    )
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY series_count DESC;