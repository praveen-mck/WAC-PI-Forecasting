WITH copa_only_series AS (
    SELECT DISTINCT
        LPAD(RIGHT(CAST(sap_cust_num AS STRING), 6), 6, '0')         AS sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')           AS mtrl_num,
        CASE
            WHEN fpa_cust_seg_cd IN ('A','B')     THEN 'CP&H'
            WHEN fpa_cust_seg_cd IN ('C','D','W') THEN 'SNA'
            WHEN fpa_cust_seg_cd IN ('F','H')     THEN 'MHS'
            ELSE 'INTERCO'
        END                                                           AS cust_segment,
        CASE
            WHEN cmpny_cd = '8545' THEN
                CASE WHEN prod_hier_1_num = '85451' THEN 'MPB Plasma' ELSE 'MPB Specialty' END
            WHEN prod_hier_1_num IN ('00030','00050')
             AND sls_ctgry_cd NOT IN ('200','250','300','400','410','500','510') THEN 'OTC'
            WHEN prod_hier_1_num = '00020'
             AND cmpny_cd <> '8545'                                   THEN 'GX'
            WHEN sls_ctgry_cd IN (
                '102','103','106','107','112','116',
                '122','123','701','703','711','806','807','816'
            )                                                         THEN 'DROP SHIP'
            WHEN mtrl_grp2_cd = 'W2'                                 THEN 'GLP-1'
            WHEN mtrl_grp2_cd IN ('R1','R2')                         THEN 'BIOSIMS'
            WHEN mtrl_grp2_cd IN ('V1','V2')                         THEN 'VAX'
            WHEN mtrl_grp2_cd IN ('S1','S3','S4','S5','S6')          THEN 'APOLLO'
            ELSE 'BX'
        END                                                           AS cust_prod_category
    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa
    WHERE post_dt BETWEEN '2025-01-01' AND '2026-12-31'
      AND cmpny_cd IN ('8000','8545')
      AND bus_type_cd NOT IN ('18','19','20')
      AND fpa_cust_seg_cd IN ('A','B','C','D','W','F','H')
      AND RIGHT(CAST(sap_cust_num AS STRING), 6) IN (
          SELECT CAST(cust_acct_id AS STRING)
          FROM uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr
          WHERE active_cust_ind = 'A'
      )
),

bt_series AS (
    SELECT DISTINCT
        LPAD(CAST(sap_cust_num_trim AS STRING), 6, '0')               AS sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')            AS mtrl_num,
        cust_segment,
        cust_prod_category
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v21
    WHERE run_id = 'BT_2025_01'
),

-- Modeling base summarized at series grain
mb_series AS (
    SELECT
        sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')            AS mtrl_num,
        cust_segment,
        cust_prod_category,
        MIN(cal_month_start_dt)                                        AS first_month,
        MAX(cal_month_start_dt)                                        AS last_month,
        -- Any rows in the BT_2025_01 forecast horizon?
        MAX(CASE WHEN cal_month_start_dt >= '2025-01-01' THEN 1 ELSE 0 END)
                                                                       AS has_horizon_months,
        -- Any trainable rows (anchor eligible)?
        MAX(CASE WHEN exclude_from_training_flag = 0
                  AND cal_month_start_dt < '2025-01-01' THEN 1 ELSE 0 END)
                                                                       AS has_trainable_history,
        MAX(exclude_from_actuals_flag)                                 AS max_excl_actuals,
        MAX(zombie_sale_flag)                                          AS max_zombie,
        MAX(exclude_from_training_flag)                                AS max_excl_training,
        MAX(regime_change_type)                                        AS regime_change_type
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21
    GROUP BY 1, 2, 3, 4
),

-- Eligibility check
eligibility AS (
    SELECT
        sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')            AS mtrl_num,
        cust_segment,
        cust_prod_category,
        groupby_key,
        data_coverage_flag
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v21
    WHERE run_id = 'BT_2025_01'
)

SELECT
    CASE
        WHEN bt.sap_cust_num_trim IS NOT NULL
            THEN 'MATCHED'
        WHEN mb.sap_cust_num_trim IS NULL
            THEN 'NOT_IN_MODELING_BASE'
        WHEN el.data_coverage_flag = 'NOT_LAUNCHED_YET'
            THEN 'NOT_LAUNCHED_BY_JUMP_OFF'
        WHEN mb.has_trainable_history = 0
            THEN 'ALL_HISTORY_EXCLUDED_FROM_TRAINING'   -- no anchor price possible
        WHEN mb.has_horizon_months = 0
            THEN 'NO_ACTIVITY_IN_FORECAST_HORIZON'      -- in base but no 2025+ months
        WHEN mb.max_zombie = 1
            THEN 'ZOMBIE_SALES_EXCLUDED'
        WHEN mb.max_excl_actuals = 1
            THEN 'EXCLUDED_FROM_ACTUALS'
        ELSE 'OTHER_MODELING_BASE_EXCLUSION'
    END                                                                AS missing_reason,
    COUNT(*)                                                           AS series_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                AS pct_of_total
FROM copa_only_series c
LEFT JOIN bt_series bt
    ON  c.sap_cust_num_trim  = bt.sap_cust_num_trim
    AND c.mtrl_num           = bt.mtrl_num
    AND c.cust_segment       = bt.cust_segment
    AND c.cust_prod_category = bt.cust_prod_category
LEFT JOIN mb_series mb
    ON  c.sap_cust_num_trim  = mb.sap_cust_num_trim
    AND c.mtrl_num           = mb.mtrl_num
    AND c.cust_segment       = mb.cust_segment
    AND c.cust_prod_category = mb.cust_prod_category
LEFT JOIN eligibility el
    ON  c.sap_cust_num_trim  = el.sap_cust_num_trim
    AND c.mtrl_num           = el.mtrl_num
    AND c.cust_segment       = el.cust_segment
    AND c.cust_prod_category = el.cust_prod_category
GROUP BY 1
ORDER BY series_count DESC;