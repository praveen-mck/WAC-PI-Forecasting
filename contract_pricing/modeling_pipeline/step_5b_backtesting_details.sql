
-- =========================================================
-- STEP 5b: BACKTESTING EVALUATION v21
-- groupby_key replaces sap_cust_num_trim+mtrl_num everywhere
-- =========================================================
 
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v21 AS
WITH joined AS (
    SELECT
        f.run_id, f.jump_off_month, f.groupby_key, f.sap_cust_num_trim, f.mtrl_num,
        f.forecast_month, f.forecast_horizon_month_num, f.forecast_year_month,
        f.sap_months, f.l2_months, f.sparse_price_confidence, f.is_sparse_price_flag,
        f.cust_segment, f.acct_classification, f.cust_prod_category,
        f.national_grp_id, f.national_grp_desc,
        f.common_grp_id, f.common_grp_desc, f.subset_l2_id_resolved,
        f.mtrl_nme_nvgton, f.ndc_num, f.product_family, f.therapeutic_class,
        f.manufacturer_id, f.manufacturer_name, f.final_product_group, f.final_product_group_level,
        f.WAC, f.total_net_revenue, f.top_100_brand_flag, f.brand_wac_rank,
        f.first_month, f.anchor_month, f.months_since_first_asof_jumpoff,
        f.anchor_contract_price, f.anchor_wac_weighted, f.anchor_wac_spread,
        f.forecast_start_contract_price, f.forecast_start_price_source,
        f.resolved_monthly_trend_pct, f.trend_source, f.forecasted_contract_price,
        f.recent_6m_months, f.latest_6_observed_months,
        a.brand_name, a.contract_price AS actual_contract_price,
        a.account_class_cd, a.wac_weighted AS actual_wac_weighted,
        a.wac_spread AS actual_wac_spread, a.total_sls_qty AS actual_sls_qty,
        a.total_net_cos AS actual_net_cos,
        COALESCE(a.wac_mom_decrease_flag,          0) AS wac_price_decrease_flag,
        COALESCE(a.wac_5pct_drop_flag,             0) AS wac_significant_decrease_flag,
        COALESCE(a.contract_price_drop_30pct_flag, 0) AS contract_price_drop_30pct_flag,
        COALESCE(a.contract_price_inc_30pct_flag,  0) AS contract_price_inc_30pct_flag
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v21 f
    LEFT JOIN (
        SELECT groupby_key, cal_month_start_dt, brand_name, contract_price,
               account_class_cd, wac_weighted, wac_spread, total_sls_qty, total_net_cos,
               wac_mom_decrease_flag, wac_5pct_drop_flag,
               contract_price_drop_30pct_flag, contract_price_inc_30pct_flag
        FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v21
        WHERE exclude_from_actuals_flag = 0
    ) a
      ON f.groupby_key   = a.groupby_key
     AND f.forecast_month = a.cal_month_start_dt
    WHERE f.forecast_month IS NOT NULL
),
 
calc AS (
    SELECT
        j.*,
        j.forecasted_contract_price * j.actual_sls_qty          AS forecasted_dollars,
        j.actual_contract_price     * j.actual_sls_qty          AS actual_dollars,
        j.forecasted_contract_price - j.actual_contract_price   AS error_contract_price,
        ABS(j.forecasted_contract_price - j.actual_contract_price)
                                                                AS ae_contract_price,
        CASE WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
            THEN (j.forecasted_contract_price - j.actual_contract_price) / j.actual_contract_price
        END                                                     AS bias_contract_price,
        CASE WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
            THEN ABS(j.forecasted_contract_price - j.actual_contract_price) / ABS(j.actual_contract_price)
        END                                                     AS ape_contract_price,
        (j.forecasted_contract_price - j.actual_contract_price) * j.actual_sls_qty
                                                                AS error_dollars,
        ABS(j.forecasted_contract_price - j.actual_contract_price) * j.actual_sls_qty
                                                                AS ae_dollars,
        CASE WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
              AND j.actual_sls_qty IS NOT NULL AND j.actual_sls_qty <> 0
            THEN (j.forecasted_contract_price - j.actual_contract_price) / j.actual_contract_price
        END                                                     AS bias_dollars,
        CASE WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
              AND j.actual_sls_qty IS NOT NULL AND j.actual_sls_qty <> 0
            THEN ABS(j.forecasted_contract_price - j.actual_contract_price) / ABS(j.actual_contract_price)
        END                                                     AS ape_dollars,
        CASE WHEN j.actual_wac_weighted IS NOT NULL AND j.actual_wac_weighted <> 0
            THEN (j.forecasted_contract_price / j.actual_wac_weighted) - 1
        END                                                     AS implied_forecast_wac_spread
    FROM joined j
),
 
run_totals AS (
    SELECT run_id,
           SUM(ABS(error_dollars))  AS total_abs_error_dollars,
           SUM(ABS(actual_dollars)) AS total_abs_actual_dollars
    FROM calc GROUP BY run_id
),
 
series_dollars AS (
    SELECT run_id, groupby_key,
           SUM(ABS(actual_dollars)) AS series_total_actual_dollars
    FROM calc GROUP BY run_id, groupby_key
),
 
series_ranked AS (
    SELECT run_id, groupby_key, series_total_actual_dollars,
           NTILE(5) OVER (
               PARTITION BY run_id
               ORDER BY series_total_actual_dollars DESC NULLS LAST
           ) AS revenue_quintile_desc
    FROM series_dollars
)
 
SELECT
    c.*,
    CASE
        WHEN c.ape_dollars IS NULL                                  THEN NULL
        WHEN c.top_100_brand_flag = 1 AND c.ape_dollars <= 0.10    THEN 1
        WHEN c.top_100_brand_flag = 1 AND c.ape_dollars >  0.10    THEN 0
        WHEN c.top_100_brand_flag = 0 AND c.ape_dollars <= 0.15    THEN 1
        WHEN c.top_100_brand_flag = 0 AND c.ape_dollars >  0.15    THEN 0
    END                                                             AS pass_flag_vs_top100_threshold,
    CASE WHEN rt.total_abs_error_dollars <> 0
        THEN ABS(c.error_dollars) / rt.total_abs_error_dollars END AS weighted_percent_error,
    CASE WHEN rt.total_abs_actual_dollars <> 0
        THEN ABS(c.actual_dollars) / rt.total_abs_actual_dollars END AS revenue_share,
    sr.revenue_quintile_desc,
    CASE WHEN c.ape_contract_price IS NOT NULL AND c.ape_contract_price < 0.20 THEN 1
         WHEN c.ape_contract_price IS NOT NULL THEN 0 ELSE NULL
    END                                                             AS pass_flag_vs_actual_error_threshold,
    CASE WHEN c.ape_dollars IS NOT NULL
          AND ((sr.revenue_quintile_desc = 1        AND c.ape_dollars <= 0.10) OR
               (sr.revenue_quintile_desc IN (2,3,4) AND c.ape_dollars <= 0.10) OR
               (sr.revenue_quintile_desc = 5        AND c.ape_dollars <= 0.20))
         THEN 1
         WHEN c.ape_dollars IS NOT NULL THEN 0 ELSE NULL
    END                                                             AS pass_flag_vs_materiality_threshold,
    CASE WHEN c.ape_dollars IS NOT NULL
          AND ((sr.revenue_quintile_desc = 1        AND c.ape_dollars > 0.03) OR
               (sr.revenue_quintile_desc IN (2,3,4) AND c.ape_dollars > 0.10) OR
               (sr.revenue_quintile_desc = 5        AND c.ape_dollars > 0.20))
          AND ABS(c.actual_dollars) > 0                            THEN 'CRITICAL'
         WHEN c.ape_contract_price IS NOT NULL
          AND c.ape_contract_price > 0.20                          THEN 'MODERATE'
         ELSE 'PASS'
    END                                                             AS review_priority,
    CASE WHEN c.forecasted_contract_price > 3 * c.anchor_contract_price THEN 1 ELSE 0
    END                                                             AS forecast_explosion_flag
FROM calc c
JOIN run_totals    rt ON c.run_id = rt.run_id
JOIN series_ranked sr ON c.run_id = sr.run_id AND c.groupby_key = sr.groupby_key
;
 
 
create or replace table uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_v21

as SELECT
    forecast_month,
    cust_segment,
    acct_classification,
    COUNT(*)                                                        AS row_cnt,
    COUNT(DISTINCT groupby_key)                                     AS series_cnt,
    SUM(actual_dollars)                                             AS sum_actual_dollars,
    AVG(ape_contract_price)                                         AS mape_contract_price,
    SUM(ae_contract_price) / NULLIF(SUM(ABS(actual_contract_price)), 0)
                                                                    AS wape_contract_price,
    SUM(ae_contract_price * actual_sls_qty)
        / NULLIF(SUM(ABS(actual_contract_price) * actual_sls_qty), 0)
                                                                    AS wmape_contract_price,
    AVG(bias_contract_price)                                        AS avg_bias_contract_price,
    AVG(ape_dollars)                                                AS mape_dollars,
    SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0)           AS wape_dollars,
    SUM(ABS(error_contract_price) * actual_sls_qty)
        / NULLIF(SUM(ABS(actual_contract_price) * actual_sls_qty), 0)
                                                                    AS wmape_dollars,
    AVG(bias_dollars)                                               AS avg_bias_dollars,
    COUNT_IF(pass_flag_vs_actual_error_threshold = 1)               AS pass_cnt_price,
    COUNT_IF(pass_flag_vs_materiality_threshold  = 1)               AS pass_cnt_materiality,
    COUNT_IF(forecast_explosion_flag             = 1)               AS explosion_row_cnt,
    COUNT_IF(pass_flag_vs_top100_threshold       = 1)               AS pass_cnt_top100_threshold
FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v21
GROUP BY forecast_month, cust_segment, acct_classification
ORDER BY forecast_month, cust_segment, acct_classification