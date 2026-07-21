CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v18 AS

WITH joined AS (
    SELECT
        f.run_id,
        f.jump_off_month,
        f.HYBRID_MODEL_KEY_3T,
        a.HYBRID_MODEL_KEY_3T_DESC,
        f.mtrl_num,
        f.forecast_month,
        f.forecast_horizon_month_num,
        f.forecast_year_month,

        f.MODEL_TIER,
        f.sap_months,
        f.l2_months,
        f.sparse_price_confidence,
        f.is_sparse_price_flag,

        f.cust_segment,
        f.acct_classification,
        f.cust_prod_category,

        f.national_grp_id,
        f.national_grp_desc,

        f.mtrl_nme_nvgton,
        f.ndc_num,
        f.product_family,
        f.therapeutic_class,
        f.manufacturer_id,
        f.manufacturer_name,
        f.final_product_group,
        f.final_product_group_level,

        f.WAC,
        f.total_net_revenue,
        a.brand_name,

        f.first_month,
        f.anchor_month,
        f.months_since_first_asof_jumpoff,

        f.anchor_contract_price,
        f.anchor_wac_weighted,
        f.anchor_wac_spread,

        f.forecast_start_contract_price,
        f.forecast_start_price_source,

        f.resolved_monthly_trend_pct,
        f.trend_source,
        f.forecasted_contract_price,

        -- UPDATED: replaced recent_12m_months / prior_12m_months /
        -- latest_12_observed_months with the 6m columns now output
        -- by contract_price_bt_forecasted_v18 after the Step 5 fix
        f.recent_6m_months,
        f.latest_6_observed_months,

        a.contract_price                        AS actual_contract_price,
        a.account_class_cd                      AS account_class_cd,
        a.wac_weighted                          AS actual_wac_weighted,
        a.wac_spread                            AS actual_wac_spread,
        a.total_sls_qty                         AS actual_sls_qty,
        a.total_net_cos                         AS actual_net_cos,

        -- ▶ price movement flags: COALESCE to 0 so first-month NULLs
        --   (no prior month available) don't propagate into counts/rates
        COALESCE(a.wac_mom_decrease_flag,          0) AS wac_price_decrease_flag,
        COALESCE(a.wac_5pct_drop_flag,             0) AS wac_significant_decrease_flag,
        COALESCE(a.contract_price_drop_30pct_flag, 0) AS contract_price_drop_30pct_flag,
        COALESCE(a.contract_price_inc_30pct_flag,  0) AS contract_price_inc_30pct_flag

    FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v18 f
    LEFT JOIN (
        SELECT
            HYBRID_MODEL_KEY_3T,
            HYBRID_MODEL_KEY_3T_DESC,
            mtrl_num,
            cal_month_start_dt,
            contract_price,
            account_class_cd,
            wac_weighted,
            wac_spread,
            total_sls_qty,
            total_net_cos,
            brand_name,
            wac_mom_decrease_flag,
            wac_5pct_drop_flag,
            contract_price_drop_30pct_flag,
            contract_price_inc_30pct_flag
        FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v18
        WHERE exclude_from_training_flag = 0
    ) a
      ON f.HYBRID_MODEL_KEY_3T = a.HYBRID_MODEL_KEY_3T
     AND f.mtrl_num             = a.mtrl_num
     AND f.forecast_month       = a.cal_month_start_dt
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

        CASE
            WHEN j.actual_contract_price IS NOT NULL
             AND j.actual_contract_price <> 0
            THEN (j.forecasted_contract_price - j.actual_contract_price)
                 / j.actual_contract_price
        END                                                     AS bias_contract_price,

        CASE
            WHEN j.actual_contract_price IS NOT NULL
             AND j.actual_contract_price <> 0
            THEN ABS(j.forecasted_contract_price - j.actual_contract_price)
                 / ABS(j.actual_contract_price)
        END                                                     AS ape_contract_price,

        (j.forecasted_contract_price - j.actual_contract_price)
            * j.actual_sls_qty                                  AS error_dollars,

        ABS(j.forecasted_contract_price - j.actual_contract_price)
            * j.actual_sls_qty                                  AS ae_dollars,

        CASE
            WHEN j.actual_contract_price IS NOT NULL
             AND j.actual_contract_price <> 0
             AND j.actual_sls_qty IS NOT NULL
             AND j.actual_sls_qty <> 0
            THEN (j.forecasted_contract_price - j.actual_contract_price)
                 / j.actual_contract_price
        END                                                     AS bias_dollars,

        CASE
            WHEN j.actual_contract_price IS NOT NULL
             AND j.actual_contract_price <> 0
             AND j.actual_sls_qty IS NOT NULL
             AND j.actual_sls_qty <> 0
            THEN ABS(j.forecasted_contract_price - j.actual_contract_price)
                 / ABS(j.actual_contract_price)
        END                                                     AS ape_dollars,

        CASE
            WHEN j.actual_wac_weighted IS NOT NULL
             AND j.actual_wac_weighted <> 0
            THEN (j.forecasted_contract_price / j.actual_wac_weighted) - 1
        END                                                     AS implied_forecast_wac_spread

    FROM joined j
),

run_totals AS (
    SELECT
        run_id,
        SUM(ABS(error_dollars))     AS total_abs_error_dollars,
        SUM(ABS(actual_dollars))    AS total_abs_actual_dollars
    FROM calc
    GROUP BY run_id
),

series_dollars AS (
    SELECT
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        SUM(ABS(actual_dollars))    AS series_total_actual_dollars
    FROM calc
    GROUP BY run_id, HYBRID_MODEL_KEY_3T, mtrl_num
),

series_ranked AS (
    SELECT
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        series_total_actual_dollars,
        NTILE(5) OVER (
            PARTITION BY run_id
            ORDER BY series_total_actual_dollars DESC NULLS LAST
        )                           AS revenue_quintile_desc
    FROM series_dollars
),

-- ▶ top 100 brand names by SUM(WAC) across all rows in the eval table
top_100_brands AS (
    SELECT brand_name
    FROM calc
    GROUP BY brand_name
    ORDER BY SUM(WAC) DESC
    LIMIT 100
)

SELECT
    c.*,

    -- ▶ 1 if this row's brand_name is in the top 100 by WAC, else 0
    CASE
        WHEN t.brand_name IS NOT NULL THEN 1
        ELSE 0
    END                                                         AS top_100_brand_flag,

    -- ▶ pass/fail using tier-aware dollar error threshold:
    --   top 100 brands  -> 10% APE threshold
    --   all others      -> 15% APE threshold
    CASE
        WHEN c.ape_dollars IS NULL THEN NULL
        WHEN t.brand_name IS NOT NULL AND c.ape_dollars <= 0.10 THEN 1
        WHEN t.brand_name IS NOT NULL AND c.ape_dollars >  0.10 THEN 0
        WHEN t.brand_name IS NULL     AND c.ape_dollars <= 0.15 THEN 1
        WHEN t.brand_name IS NULL     AND c.ape_dollars >  0.15 THEN 0
    END                                                         AS pass_flag_vs_top100_threshold,

    CASE
        WHEN rt.total_abs_error_dollars <> 0
        THEN ABS(c.error_dollars) / rt.total_abs_error_dollars
    END                                                         AS weighted_percent_error,

    CASE
        WHEN rt.total_abs_actual_dollars <> 0
        THEN ABS(c.actual_dollars) / rt.total_abs_actual_dollars
    END                                                         AS revenue_share,

    sr.revenue_quintile_desc,

    CASE
        WHEN c.ape_contract_price IS NOT NULL
         AND c.ape_contract_price < 0.20 THEN 1
        WHEN c.ape_contract_price IS NOT NULL    THEN 0
        ELSE NULL
    END                                                         AS pass_flag_vs_actual_error_threshold,

    CASE
        WHEN c.ape_dollars IS NOT NULL
         AND (
                (sr.revenue_quintile_desc = 1        AND c.ape_dollars <= 0.10) OR
                (sr.revenue_quintile_desc IN (2,3,4) AND c.ape_dollars <= 0.10) OR
                (sr.revenue_quintile_desc = 5        AND c.ape_dollars <= 0.20)
             )
        THEN 1
        WHEN c.ape_dollars IS NOT NULL           THEN 0
        ELSE NULL
    END                                                         AS pass_flag_vs_materiality_threshold,

    CASE
        WHEN c.ape_dollars IS NOT NULL
         AND (
                (sr.revenue_quintile_desc = 1        AND c.ape_dollars > 0.03) OR
                (sr.revenue_quintile_desc IN (2,3,4) AND c.ape_dollars > 0.10) OR
                (sr.revenue_quintile_desc = 5        AND c.ape_dollars > 0.20)
             )
         AND ABS(c.actual_dollars) > 0
        THEN 'CRITICAL'
        WHEN c.ape_contract_price IS NOT NULL
         AND c.ape_contract_price > 0.20         THEN 'MODERATE'
        ELSE 'PASS'
    END                                                         AS review_priority,

    CASE
        WHEN c.forecasted_contract_price > 3 * c.anchor_contract_price THEN 1
        ELSE 0
    END                                                         AS forecast_explosion_flag

FROM calc c
JOIN run_totals    rt ON c.run_id              = rt.run_id
JOIN series_ranked sr
  ON c.run_id              = sr.run_id
 AND c.HYBRID_MODEL_KEY_3T = sr.HYBRID_MODEL_KEY_3T
 AND c.mtrl_num             = sr.mtrl_num
LEFT JOIN top_100_brands t
  ON c.brand_name = t.brand_name
;


-- =====================================================================
-- SUMMARY — unchanged
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_run_v18 AS
SELECT
    run_id,
    MODEL_TIER,
    sparse_price_confidence,

    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,

    MAX(WAC)                                            AS WAC,
    MAX(total_net_revenue)                              AS total_net_revenue,
    MAX(brand_name)                                     AS brand_name,

    AVG(ape_contract_price)                             AS mape_contract_price,
    SUM(ae_contract_price)
        / NULLIF(SUM(ABS(actual_contract_price)), 0)    AS wape_contract_price,
    SUM(ae_contract_price * actual_sls_qty)
        / NULLIF(SUM(ABS(actual_contract_price) * actual_sls_qty), 0)
                                                        AS wmape_contract_price,
    AVG(bias_contract_price)                            AS avg_bias_contract_price,

    AVG(ape_dollars)                                    AS mape_dollars,
    SUM(ae_dollars)
        / NULLIF(SUM(ABS(actual_dollars)), 0)           AS wape_dollars,
    SUM(ae_dollars)
        / NULLIF(SUM(ABS(actual_dollars)), 0)           AS wmape_dollars,
    AVG(bias_dollars)                                   AS avg_bias_dollars,

    COUNT_IF(pass_flag_vs_actual_error_threshold = 1)   AS pass_cnt_price,
    COUNT_IF(pass_flag_vs_actual_error_threshold = 0)   AS fail_cnt_price,
    COUNT_IF(pass_flag_vs_materiality_threshold  = 1)   AS pass_cnt_materiality,
    COUNT_IF(pass_flag_vs_materiality_threshold  = 0)   AS fail_cnt_materiality,
    COUNT_IF(forecast_explosion_flag             = 1)   AS explosion_row_cnt,

    COUNT_IF(top_100_brand_flag              = 1)       AS top_100_brand_row_cnt,
    COUNT_IF(pass_flag_vs_top100_threshold   = 1)       AS pass_cnt_top100_threshold,
    COUNT_IF(pass_flag_vs_top100_threshold   = 0)       AS fail_cnt_top100_threshold,

    COUNT_IF(wac_price_decrease_flag        = 1)        AS wac_price_decrease_cnt,
    COUNT_IF(wac_significant_decrease_flag  = 1)        AS wac_significant_decrease_cnt,
    COUNT_IF(contract_price_drop_30pct_flag = 1)        AS contract_price_drop_30pct_cnt,
    COUNT_IF(contract_price_inc_30pct_flag  = 1)        AS contract_price_inc_30pct_cnt,

    COALESCE(COUNT_IF(wac_price_decrease_flag        = 1) / NULLIF(COUNT(*), 0), 0)
                                                        AS wac_price_decrease_rate,
    COALESCE(COUNT_IF(wac_significant_decrease_flag  = 1) / NULLIF(COUNT(*), 0), 0)
                                                        AS wac_significant_decrease_rate,
    COALESCE(COUNT_IF(contract_price_drop_30pct_flag = 1) / NULLIF(COUNT(*), 0), 0)
                                                        AS contract_price_drop_30pct_rate,
    COALESCE(COUNT_IF(contract_price_inc_30pct_flag  = 1) / NULLIF(COUNT(*), 0), 0)
                                                        AS contract_price_inc_30pct_rate

FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v18
GROUP BY run_id, MODEL_TIER, sparse_price_confidence
ORDER BY run_id, MODEL_TIER, sparse_price_confidence
;
