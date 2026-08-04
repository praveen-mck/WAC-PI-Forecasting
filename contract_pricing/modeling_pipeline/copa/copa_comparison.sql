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
        MAX(c.bill_type_cd)                                          AS bill_type_cd,
        MAX(CASE WHEN c.bill_type_cd IN (
                'ZPD1','ZPD5','ZPDS','ZPF2','ZPS1','ZPS3','ZPS6','ZPS7')
             THEN 1 ELSE 0 END)                                      AS has_eligible_bill_type,
        MAX(CASE WHEN c.sls_qty_bex > 0 AND c.net_cos > 0 THEN 1 ELSE 0 END)
                                                                     AS has_valid_txn,
        SUM(c.sls_qty_bex)                                           AS copa_sls_qty,
        SUM(c.net_cos)                                               AS copa_net_cos
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
    GROUP BY 1, 2, 3, 4
),

bt_series AS (
    SELECT DISTINCT
        LPAD(CAST(sap_cust_num_trim AS STRING), 6, '0')              AS sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')           AS mtrl_num,
        cust_segment,
        cust_prod_category
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v21
    WHERE run_id = 'BT_2025_01'
),

mb_any AS (
    SELECT DISTINCT
        sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')           AS mtrl_num,
        cust_segment,
        cust_prod_category
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21
),

mb_clean AS (
    SELECT
        sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')           AS mtrl_num,
        cust_segment,
        cust_prod_category,
        MAX(exclude_from_training_flag)                               AS any_excluded,
        MIN(exclude_from_training_flag)                               AS all_excluded,
        MAX(zombie_sale_flag)                                         AS any_zombie,
        MAX(contract_price_above_wac_flag)                            AS any_above_wac,
        MAX(invalid_wac_flag)                                         AS any_invalid_wac,
        MAX(contract_price_outlier_flag)                              AS any_outlier,
        MAX(regime_change_type)                                       AS regime_change_type
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21
    GROUP BY 1, 2, 3, 4
),

diagnosed AS (
    SELECT
        c.sap_cust_num_trim,
        c.mtrl_num,
        c.cust_segment,
        c.cust_prod_category,
        c.has_eligible_bill_type,
        c.has_valid_txn,
        c.copa_sls_qty,
        c.copa_net_cos,
        mb.regime_change_type,
        mb.any_zombie,
        mb.any_above_wac,
        mb.any_invalid_wac,
        mb.any_outlier,

        CASE
            WHEN bt.sap_cust_num_trim IS NOT NULL
                THEN 'MATCHED'
            WHEN c.has_eligible_bill_type = 0
                THEN 'COPA_ONLY_INELIGIBLE_BILL_TYPE'
            WHEN c.has_valid_txn = 1
             AND mba.sap_cust_num_trim IS NULL
                THEN 'COPA_ONLY_NOT_IN_MODELING_BASE'
            WHEN mba.sap_cust_num_trim IS NOT NULL
             AND mb.all_excluded = 1
             AND mb.any_zombie = 1
                THEN 'COPA_ONLY_ALL_ROWS_ZOMBIE_EXCLUDED'
            WHEN mba.sap_cust_num_trim IS NOT NULL
             AND mb.all_excluded = 1
             AND mb.any_above_wac = 1
                THEN 'COPA_ONLY_ALL_ROWS_ABOVE_WAC_EXCLUDED'
            WHEN mba.sap_cust_num_trim IS NOT NULL
             AND mb.all_excluded = 1
             AND mb.any_invalid_wac = 1
                THEN 'COPA_ONLY_ALL_ROWS_INVALID_WAC_EXCLUDED'
            WHEN mba.sap_cust_num_trim IS NOT NULL
             AND mb.all_excluded = 1
             AND mb.any_outlier = 1
                THEN 'COPA_ONLY_ALL_ROWS_OUTLIER_EXCLUDED'
            WHEN mba.sap_cust_num_trim IS NOT NULL
             AND mb.all_excluded = 1
                THEN 'COPA_ONLY_ALL_ROWS_EXCLUDED_OTHER'
            WHEN mba.sap_cust_num_trim IS NOT NULL
             AND mb.all_excluded = 0
                THEN 'COPA_ONLY_IN_BASE_NO_BT_OUTPUT'
            WHEN c.has_valid_txn = 0
                THEN 'COPA_ONLY_NO_VALID_TXNS'
            ELSE 'COPA_ONLY_UNCLASSIFIED'
        END                                                           AS exclusion_reason

    FROM copa_grain c
    LEFT JOIN bt_series bt
        ON  c.sap_cust_num_trim  = bt.sap_cust_num_trim
        AND c.mtrl_num           = bt.mtrl_num
        AND c.cust_segment       = bt.cust_segment
        AND c.cust_prod_category = bt.cust_prod_category
    LEFT JOIN mb_any mba
        ON  c.sap_cust_num_trim  = mba.sap_cust_num_trim
        AND c.mtrl_num           = mba.mtrl_num
        AND c.cust_segment       = mba.cust_segment
        AND c.cust_prod_category = mba.cust_prod_category
    LEFT JOIN mb_clean mb
        ON  c.sap_cust_num_trim  = mb.sap_cust_num_trim
        AND c.mtrl_num           = mb.mtrl_num
        AND c.cust_segment       = mb.cust_segment
        AND c.cust_prod_category = mb.cust_prod_category
),

agg AS (
    SELECT
        exclusion_reason,
        cust_segment,
        cust_prod_category,
        COUNT(*)                                                       AS series_count,
        SUM(copa_net_cos)                                              AS total_copa_net_cos,
        AVG(copa_net_cos)                                              AS avg_net_cos_per_series,
        SUM(copa_sls_qty)                                              AS total_copa_sls_qty
    FROM diagnosed
    GROUP BY 1, 2, 3
)

SELECT
    exclusion_reason,
    cust_segment,
    cust_prod_category,
    series_count,
    ROUND(100.0 * series_count / SUM(series_count) OVER (), 2)        AS pct_of_total_series,
    total_copa_net_cos,
    ROUND(100.0 * total_copa_net_cos
        / SUM(total_copa_net_cos) OVER (), 2)                          AS pct_of_total_dollars,
    avg_net_cos_per_series,
    total_copa_sls_qty
FROM agg
ORDER BY
    exclusion_reason,
    total_copa_net_cos DESC NULLS LAST
;