
WITH copa_grain AS (
    SELECT
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
        END                                                           AS cust_prod_category,
        SUM(net_cos)                                                  AS copa_net_cos,
        SUM(sls_qty_bex)                                              AS copa_sls_qty
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
    GROUP BY 1, 2, 3, 4
),

bt_series AS (
    SELECT
        LPAD(CAST(sap_cust_num_trim AS STRING), 6, '0')               AS sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')            AS mtrl_num,
        cust_segment,
        cust_prod_category,
        SUM(forecasted_contract_price * actual_sls_qty)
            / NULLIF(SUM(actual_sls_qty), 0)                           AS forecasted_contract_price
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v21
    WHERE run_id = 'BT_2025_01'
    GROUP BY 1, 2, 3, 4
),

mb_series AS (
    SELECT
        sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')            AS mtrl_num,
        cust_segment,
        cust_prod_category,
        MIN(cal_month_start_dt)                                        AS first_month,
        MAX(cal_month_start_dt)                                        AS last_month,
        MAX(CASE WHEN cal_month_start_dt >= '2025-01-01' THEN 1 ELSE 0 END)
                                                                       AS has_horizon_months,
        MAX(CASE WHEN exclude_from_training_flag = 0
                  AND cal_month_start_dt < '2025-01-01' THEN 1 ELSE 0 END)
                                                                       AS has_trainable_history,
        MAX(zombie_sale_flag)                                          AS max_zombie,
        MAX(exclude_from_training_flag)                                AS max_excl_training
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21
    GROUP BY 1, 2, 3, 4
),

eligibility AS (
    SELECT
        sap_cust_num_trim,
        REGEXP_REPLACE(CAST(mtrl_num AS STRING), '^0+', '')            AS mtrl_num,
        cust_segment,
        cust_prod_category,
        data_coverage_flag
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v21
    WHERE run_id = 'BT_2025_01'
),

diagnosed AS (
    SELECT
        c.copa_net_cos,
        c.copa_sls_qty,
        bt.forecasted_contract_price * c.copa_sls_qty                  AS forecasted_ncos,
        CASE
            WHEN bt.sap_cust_num_trim IS NOT NULL
                THEN 'MATCHED'
            WHEN mb.sap_cust_num_trim IS NULL
                THEN 'NOT_IN_MODELING_BASE'
            WHEN el.data_coverage_flag = 'NOT_LAUNCHED_YET'
                THEN 'NOT_LAUNCHED_BY_JUMP_OFF'
            WHEN mb.has_trainable_history = 0
                THEN 'ALL_HISTORY_EXCLUDED_FROM_TRAINING'
            WHEN mb.has_horizon_months = 0
                THEN 'NO_ACTIVITY_IN_FORECAST_HORIZON'
            ELSE 'OTHER'
        END                                                            AS missing_reason
    FROM copa_grain c
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
),

agg AS (
    SELECT
        missing_reason,
        COUNT(*)                                                       AS series_count,
        SUM(copa_net_cos)                                              AS total_copa_net_cos,
        SUM(copa_sls_qty)                                              AS total_copa_sls_qty,
        SUM(forecasted_ncos)                                           AS total_forecasted_ncos,
        SUM(forecasted_ncos) - SUM(copa_net_cos)                      AS forecast_vs_actual_abs,
        ROUND(100.0 * (SUM(forecasted_ncos) - SUM(copa_net_cos))
            / NULLIF(ABS(SUM(copa_net_cos)), 0), 2)                    AS forecast_vs_actual_pct
    FROM diagnosed
    GROUP BY 1
)

-- ── Breakdown by reason ───────────────────────────────────────────────────────
SELECT
    'BY_REASON'                                                        AS row_type,
    missing_reason,
    series_count,
    ROUND(100.0 * series_count / SUM(series_count) OVER (), 2)         AS pct_of_total_series,
    total_copa_net_cos,
    ROUND(100.0 * total_copa_net_cos
        / SUM(total_copa_net_cos) OVER (), 2)                           AS pct_of_total_dollars,
    total_copa_sls_qty,
    total_forecasted_ncos,
    forecast_vs_actual_abs,
    forecast_vs_actual_pct
FROM agg

UNION ALL

-- ── Matched subtotal ──────────────────────────────────────────────────────────
SELECT
    'SUBTOTAL_MATCHED',
    'MATCHED',
    SUM(CASE WHEN missing_reason = 'MATCHED' THEN series_count END),
    ROUND(100.0 * SUM(CASE WHEN missing_reason = 'MATCHED' THEN series_count END)
        / NULLIF(SUM(series_count), 0), 2),
    SUM(CASE WHEN missing_reason = 'MATCHED' THEN total_copa_net_cos END),
    ROUND(100.0 * SUM(CASE WHEN missing_reason = 'MATCHED' THEN total_copa_net_cos END)
        / NULLIF(SUM(total_copa_net_cos), 0), 2),
    SUM(CASE WHEN missing_reason = 'MATCHED' THEN total_copa_sls_qty END),
    SUM(CASE WHEN missing_reason = 'MATCHED' THEN total_forecasted_ncos END),
    SUM(CASE WHEN missing_reason = 'MATCHED' THEN forecast_vs_actual_abs END),
    ROUND(100.0 * SUM(CASE WHEN missing_reason = 'MATCHED' THEN forecast_vs_actual_abs END)
        / NULLIF(ABS(SUM(CASE WHEN missing_reason = 'MATCHED' THEN total_copa_net_cos END)), 0), 2)
FROM agg

UNION ALL

-- ── Unmatched subtotal (COPA with no BT forecast) ─────────────────────────────
SELECT
    'SUBTOTAL_UNMATCHED',
    'COPA_ONLY_NO_BT_FORECAST',
    SUM(CASE WHEN missing_reason != 'MATCHED' THEN series_count END),
    ROUND(100.0 * SUM(CASE WHEN missing_reason != 'MATCHED' THEN series_count END)
        / NULLIF(SUM(series_count), 0), 2),
    SUM(CASE WHEN missing_reason != 'MATCHED' THEN total_copa_net_cos END),
    ROUND(100.0 * SUM(CASE WHEN missing_reason != 'MATCHED' THEN total_copa_net_cos END)
        / NULLIF(SUM(total_copa_net_cos), 0), 2),
    SUM(CASE WHEN missing_reason != 'MATCHED' THEN total_copa_sls_qty END),
    NULL,   -- no forecasted_ncos for unmatched
    NULL,   -- no forecast_vs_actual_abs for unmatched
    NULL    -- no forecast_vs_actual_pct for unmatched
FROM agg

UNION ALL

-- ── Grand total ───────────────────────────────────────────────────────────────
SELECT
    'GRAND_TOTAL',
    'ALL',
    SUM(series_count),
    100.00,
    SUM(total_copa_net_cos),
    100.00,
    SUM(total_copa_sls_qty),
    SUM(total_forecasted_ncos),
    SUM(forecast_vs_actual_abs),
    ROUND(100.0 * SUM(forecast_vs_actual_abs)
        / NULLIF(ABS(SUM(CASE WHEN missing_reason = 'MATCHED'
                              THEN total_copa_net_cos END)), 0), 2)
FROM agg

ORDER BY
    CASE row_type
        WHEN 'BY_REASON'          THEN 1
        WHEN 'SUBTOTAL_MATCHED'   THEN 2
        WHEN 'SUBTOTAL_UNMATCHED' THEN 3
        WHEN 'GRAND_TOTAL'        THEN 4
    END,
    total_copa_net_cos DESC NULLS LAST
;