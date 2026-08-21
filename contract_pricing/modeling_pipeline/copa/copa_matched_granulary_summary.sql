WITH

-- Run to analyze — change run_id here to switch runs.
-- All date boundaries are derived from contract_price_bt_runs_v23 (step 0).
run_ranges AS (
    SELECT
        run_id,
        jump_off_month              AS start_dt,
        forecast_horizon_end_dt     AS end_dt
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v23
    WHERE run_id = 'BT_2025_01'
),

copa_grain AS (
    SELECT
        LPAD(RIGHT(CAST(c.sap_cust_num AS STRING), 6), 6, '0')      AS sap_cust_num_trim,
        REGEXP_REPLACE(CAST(c.mtrl_num AS STRING), '^0+', '')        AS mtrl_num,
        CAST(DATE_TRUNC('month', c.post_dt) AS DATE)                 AS cal_month,

        -- Derived same way as modeling base base_layer
        CASE
            WHEN c.fpa_cust_seg_cd IN ('A','B')     THEN 'CP&H'
            WHEN c.fpa_cust_seg_cd IN ('C','D','W') THEN 'SNA'
            WHEN c.fpa_cust_seg_cd IN ('F','H')     THEN 'MHS'
            ELSE 'INTERCO'
        END                                                          AS cust_segment,

        -- Derived same way as CUST_PROD_CATEGORY in base_layer
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
        SUM(c.net_cos)                                               AS copa_net_cos
    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa c
    CROSS JOIN run_ranges rr
    WHERE c.post_dt BETWEEN rr.start_dt AND rr.end_dt
      AND c.cmpny_cd IN ('8000','8545')
      AND c.bus_type_cd NOT IN ('18','19','20')
      -- AND c.sls_qty_bex > 0
      -- AND c.sls_qty_bex IS NOT NULL
      -- AND c.net_cos IS NOT NULL
      -- AND c.net_cos > 0
      -- AND c.bill_type_cd IN ('ZPD1','ZPD5','ZPDS','ZPF2','ZPS1','ZPS3','ZPS6','ZPS7')
      AND c.fpa_cust_seg_cd IN ('A','B','C','D','W','F','H')
      AND RIGHT(CAST(c.sap_cust_num AS STRING), 6) IN (
          SELECT CAST(cust_acct_id AS STRING)
          FROM uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr
          WHERE active_cust_ind = 'A'
      )
    GROUP BY 1, 2, 3, 4, 5
),

bt_grain AS (
    SELECT
        LPAD(CAST(sap_cust_num_trim AS STRING), 6, '0')              AS sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')           AS mtrl_num,
        CAST(DATE_TRUNC('month', forecast_month) AS DATE)             AS cal_month,
        cust_segment,
        cust_prod_category,
        SUM(forecasted_contract_price * actual_sls_qty)
            / NULLIF(SUM(actual_sls_qty), 0)                          AS forecasted_contract_price,
        MAX(groupby_key)                                              AS groupby_key,
        MAX(acct_classification)                                      AS acct_classification,
        MAX(product_family)                                           AS product_family,
        MAX(brand_name)                                               AS brand_name,
        MAX(sparse_price_confidence)                                  AS sparse_price_confidence,
        MAX(is_sparse_price_flag)                                     AS is_sparse_price_flag,
        MAX(review_priority)                                          AS review_priority
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v21
    CROSS JOIN run_ranges rr
    WHERE run_id = rr.run_id
    GROUP BY 1, 2, 3, 4, 5
),

detail AS (
    SELECT
        COALESCE(c.sap_cust_num_trim,  bt.sap_cust_num_trim)         AS sap_cust_num_trim,
        COALESCE(c.mtrl_num,           bt.mtrl_num)                   AS mtrl_num,
        COALESCE(c.cal_month,          bt.cal_month)                  AS cal_month,
        COALESCE(c.cust_segment,       bt.cust_segment)               AS cust_segment,
        COALESCE(c.cust_prod_category, bt.cust_prod_category)         AS cust_prod_category,
        bt.groupby_key,
        bt.acct_classification,
        bt.product_family,
        bt.brand_name,
        bt.sparse_price_confidence,
        bt.is_sparse_price_flag,
        bt.review_priority,
        c.copa_sls_qty,
        c.copa_net_cos,
        c.copa_net_cos / NULLIF(c.copa_sls_qty, 0)                    AS copa_avg_ncos_price,
        bt.forecasted_contract_price,
        bt.forecasted_contract_price * c.copa_sls_qty                 AS forecasted_ncos,
        (bt.forecasted_contract_price * c.copa_sls_qty)
            - c.copa_net_cos                                           AS forecast_vs_actual_abs,
        CASE
            WHEN c.copa_net_cos IS NULL OR c.copa_net_cos = 0 THEN NULL
            ELSE ((bt.forecasted_contract_price * c.copa_sls_qty) - c.copa_net_cos)
                 / ABS(c.copa_net_cos)
        END                                                            AS forecast_vs_actual_pct,
        CASE WHEN bt.sap_cust_num_trim IS NOT NULL THEN 1 ELSE 0 END  AS has_bt_forecast,
        CASE WHEN c.sap_cust_num_trim  IS NOT NULL THEN 1 ELSE 0 END  AS has_copa_actuals
    FROM copa_grain c
    FULL OUTER JOIN bt_grain bt
        ON  c.sap_cust_num_trim  = bt.sap_cust_num_trim
        AND c.mtrl_num           = bt.mtrl_num
        AND c.cal_month          = bt.cal_month
        AND c.cust_segment       = bt.cust_segment
        AND c.cust_prod_category = bt.cust_prod_category
),

series AS (
    SELECT
        sap_cust_num_trim,
        mtrl_num,
        cust_segment,
        cust_prod_category,
        MAX(groupby_key)                                              AS groupby_key,
        MAX(acct_classification)                                      AS acct_classification,
        MAX(product_family)                                           AS product_family,
        MAX(brand_name)                                               AS brand_name,
        MAX(has_bt_forecast)                                          AS has_bt_forecast,
        MAX(has_copa_actuals)                                         AS has_copa_actuals,
        COUNT(DISTINCT cal_month)                                     AS total_months,
        COUNT(DISTINCT CASE WHEN has_bt_forecast = 1
                             AND has_copa_actuals = 1
                             THEN cal_month END)                      AS matched_months,
        SUM(copa_sls_qty)                                             AS total_copa_sls_qty,
        SUM(copa_net_cos)                                             AS total_copa_net_cos,
        SUM(copa_net_cos) / NULLIF(SUM(copa_sls_qty), 0)             AS copa_avg_ncos_price,
        SUM(forecasted_ncos)                                          AS total_forecasted_ncos,
        SUM(forecast_vs_actual_abs)                                   AS total_forecast_vs_actual_abs,
        CASE
            WHEN SUM(copa_net_cos) IS NULL OR SUM(copa_net_cos) = 0 THEN NULL
            ELSE SUM(forecast_vs_actual_abs) / ABS(SUM(copa_net_cos))
        END                                                           AS forecast_vs_actual_pct
    FROM detail
    GROUP BY 1, 2, 3, 4
    HAVING MAX(has_copa_actuals) = 1
)

SELECT
    COUNT(*)                                                          AS total_series,
    SUM(has_copa_actuals)                                             AS series_with_copa,
    SUM(has_bt_forecast)                                              AS series_with_bt_forecast,
    SUM(CASE WHEN has_bt_forecast = 1
              AND has_copa_actuals = 1 THEN 1 ELSE 0 END)            AS series_matched,
    SUM(CASE WHEN has_copa_actuals = 1
              AND has_bt_forecast  = 0 THEN 1 ELSE 0 END)            AS series_copa_only,
    SUM(CASE WHEN has_bt_forecast  = 1
              AND has_copa_actuals = 0 THEN 1 ELSE 0 END)            AS series_bt_only,
    ROUND(100.0 * SUM(CASE WHEN has_bt_forecast = 1
                            AND has_copa_actuals = 1 THEN 1 ELSE 0 END)
                / NULLIF(SUM(has_copa_actuals), 0), 2)               AS pct_copa_series_with_bt_forecast,
    SUM(total_copa_net_cos)                                           AS total_copa_net_cos,
    SUM(CASE WHEN has_bt_forecast = 1
             THEN total_copa_net_cos END)                             AS copa_net_cos_with_bt_forecast,
    ROUND(100.0 * SUM(CASE WHEN has_bt_forecast = 1
                            THEN total_copa_net_cos END)
                / NULLIF(SUM(total_copa_net_cos), 0), 2)             AS pct_copa_dollars_with_bt_forecast,
    SUM(total_forecasted_ncos)                                        AS total_forecasted_ncos,
    SUM(total_forecast_vs_actual_abs)                                 AS total_forecast_vs_actual_abs,
    ROUND(100.0 * SUM(total_forecast_vs_actual_abs)
                / NULLIF(SUM(CASE WHEN has_bt_forecast = 1
                                  THEN total_copa_net_cos END), 0), 2) AS overall_forecast_error_pct,
    -- Segment breakdown
    SUM(CASE WHEN cust_segment = 'CP&H'
             THEN total_copa_net_cos END)                             AS copa_net_cos_cph,
    ROUND(100.0 * SUM(CASE WHEN cust_segment = 'CP&H'
                            AND has_bt_forecast = 1
                            THEN total_copa_net_cos END)
                / NULLIF(SUM(CASE WHEN cust_segment = 'CP&H'
                                  THEN total_copa_net_cos END), 0), 2) AS pct_dollars_covered_cph,
    SUM(CASE WHEN cust_segment = 'SNA'
             THEN total_copa_net_cos END)                             AS copa_net_cos_sna,
    ROUND(100.0 * SUM(CASE WHEN cust_segment = 'SNA'
                            AND has_bt_forecast = 1
                            THEN total_copa_net_cos END)
                / NULLIF(SUM(CASE WHEN cust_segment = 'SNA'
                                  THEN total_copa_net_cos END), 0), 2) AS pct_dollars_covered_sna,
    SUM(CASE WHEN cust_segment = 'MHS'
             THEN total_copa_net_cos END)                             AS copa_net_cos_mhs,
    ROUND(100.0 * SUM(CASE WHEN cust_segment = 'MHS'
                            AND has_bt_forecast = 1
                            THEN total_copa_net_cos END)
                / NULLIF(SUM(CASE WHEN cust_segment = 'MHS'
                                  THEN total_copa_net_cos END), 0), 2) AS pct_dollars_covered_mhs
FROM series;