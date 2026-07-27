/* =====================================================================
   CONTRACT PRICE BACKTEST PIPELINE v20
   ---------------------------------------------------------------------
   Changes from v18:

   All steps:
     - All table references updated to v20

   STEP 1 (contract_price_bt_series_profile_v20):
     - Replaced self-contained ranked/first_row/last_row/agg CTEs with
       a direct JOIN to contract_price_history_profile_v20. Eliminates
       duplicated logic; series profile now inherits all flag-aware
       history metrics (training-clean first/last/avg) from step 2.

   STEP 7 (contract_price_bt_future_actual_months_v20):
     - Source is now full base table (no flag filter) so that all
       actual months are available for backtesting evaluation,
       including rows excluded from training.
       Actuals evaluation uses exclude_from_actuals_flag = 0 filter
       in step 5b rather than pre-filtering here.
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: BACKTEST RUNS — unchanged
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_runs_v20 AS
SELECT
    'BT_2024_01' AS run_id,
    TO_DATE('2024-01-01') AS jump_off_month,
    2 AS lookback_years,
    ADD_MONTHS(TO_DATE('2024-01-01'), -24) AS history_start_dt,
    DATE_SUB(TO_DATE('2024-01-01'), 1) AS history_end_dt
UNION ALL
SELECT
    'BT_2024_04' AS run_id,
    TO_DATE('2024-04-01') AS jump_off_month,
    2 AS lookback_years,
    ADD_MONTHS(TO_DATE('2024-04-01'), -24) AS history_start_dt,
    DATE_SUB(TO_DATE('2024-04-01'), 1) AS history_end_dt
UNION ALL
SELECT
    'BT_2025_01' AS run_id,
    TO_DATE('2025-01-01') AS jump_off_month,
    1 AS lookback_years,
    ADD_MONTHS(TO_DATE('2025-01-01'), -12) AS history_start_dt,
    DATE_SUB(TO_DATE('2025-01-01'), 1) AS history_end_dt
;


/* ---------------------------------------------------------------------
   STEP 1: GLOBAL SERIES PROFILE
   ---------------------------------------------------------------------
   Changed from v18: self-contained CTEs replaced with JOIN to
   contract_price_history_profile_v20. All descriptor, lifecycle,
   and aggregate columns now sourced from the flag-aware history
   profile built in step 2.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v20 AS
SELECT
    hp.HYBRID_MODEL_KEY_3T,
    hp.mtrl_num,
    hp.MODEL_TIER,
    hp.SAP_MONTHS                   AS sap_months,
    hp.L2_MONTHS                    AS l2_months,
    hp.cust_segment,
    hp.acct_classification,
    hp.cust_prod_category,
    hp.national_grp_id,
    hp.national_grp_desc,
    hp.mtrl_nme_nvgton,
    hp.ndc_num,
    hp.product_family,
    hp.therapeutic_class,
    hp.manufacturer_id,
    hp.manufacturer_name,
    hp.final_product_group,
    -- final_product_group_level not in history profile agg; pull from base max
    MAX(b.final_product_group_level) AS final_product_group_level,
    MAX(b.WAC)                       AS WAC,
    MAX(b.TOTAL_NET_REVENUE)         AS Total_Net_Revenue,
    hp.first_month,
    hp.last_month                    AS last_actual_month,
    hp.first_contract_price,
    hp.last_contract_price           AS last_actual_contract_price,
    hp.last_wac_spread               AS last_actual_wac_spread,
    hp.top_100_brand_flag,
    hp.brand_wac_rank
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v20 hp
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v20 b
  ON hp.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
 AND hp.mtrl_num             = b.mtrl_num
GROUP BY
    hp.HYBRID_MODEL_KEY_3T,
    hp.mtrl_num,
    hp.MODEL_TIER,
    hp.SAP_MONTHS,
    hp.L2_MONTHS,
    hp.cust_segment,
    hp.acct_classification,
    hp.cust_prod_category,
    hp.national_grp_id,
    hp.national_grp_desc,
    hp.mtrl_nme_nvgton,
    hp.ndc_num,
    hp.product_family,
    hp.therapeutic_class,
    hp.manufacturer_id,
    hp.manufacturer_name,
    hp.final_product_group,
    hp.first_month,
    hp.last_month,
    hp.first_contract_price,
    hp.last_contract_price,
    hp.last_wac_spread,
    hp.top_100_brand_flag,
    hp.brand_wac_rank
;


/* ---------------------------------------------------------------------
   STEP 2: RUN ELIGIBILITY — unchanged logic, v20 references
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v20 AS
SELECT
    r.run_id,
    r.jump_off_month,
    r.lookback_years,
    r.history_start_dt,
    r.history_end_dt,
    sp.HYBRID_MODEL_KEY_3T,
    sp.mtrl_num,
    sp.MODEL_TIER,
    sp.sap_months,
    sp.l2_months,
    sp.cust_segment,
    sp.acct_classification,
    sp.cust_prod_category,
    sp.national_grp_id,
    sp.national_grp_desc,
    sp.mtrl_nme_nvgton,
    sp.ndc_num,
    sp.product_family,
    sp.therapeutic_class,
    sp.manufacturer_id,
    sp.manufacturer_name,
    sp.final_product_group,
    sp.final_product_group_level,
    sp.WAC,
    sp.Total_Net_Revenue,
    sp.first_month,
    sp.last_actual_month,
    sp.top_100_brand_flag,
    sp.brand_wac_rank,
    CASE
        WHEN sp.first_month IS NOT NULL AND sp.first_month <= r.history_end_dt THEN 1
        ELSE 0
    END AS is_eligible_for_run,
    CASE
        WHEN sp.first_month IS NULL            THEN 'NO_HISTORY'
        WHEN sp.first_month > r.history_end_dt THEN 'NOT_LAUNCHED_YET'
        ELSE 'ELIGIBLE'
    END AS data_coverage_flag
FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v20 r
CROSS JOIN uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v20 sp
;


/* ---------------------------------------------------------------------
   STEP 3: RUN-SPECIFIC LAST ACTUAL (RAW) — unchanged logic, v20 refs
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v20 AS
WITH eligible AS (
    SELECT * FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v20
    WHERE is_eligible_for_run = 1
),
raw_hist AS (
    SELECT
        e.run_id,
        e.jump_off_month,
        e.history_end_dt,
        b.HYBRID_MODEL_KEY_3T,
        b.mtrl_num,
        b.cal_month_start_dt,
        b.contract_price,
        b.wac_weighted,
        b.wac_spread,
        b.total_sls_qty,
        b.total_net_cos,
        ROW_NUMBER() OVER (
            PARTITION BY e.run_id, b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v20 b
      ON e.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
     AND e.mtrl_num = b.mtrl_num
     AND b.cal_month_start_dt <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
)
SELECT
    run_id,
    jump_off_month,
    history_end_dt,
    HYBRID_MODEL_KEY_3T,
    mtrl_num,
    cal_month_start_dt  AS anchor_month,
    contract_price      AS anchor_contract_price,
    wac_weighted        AS anchor_wac_weighted,
    wac_spread          AS anchor_wac_spread,
    total_sls_qty       AS anchor_total_sls_qty,
    total_net_cos       AS anchor_total_net_cos
FROM raw_hist
WHERE rn = 1
;


/* ---------------------------------------------------------------------
   STEP 4 (BT): LATEST OBSERVED PRICE WINDOW — unchanged logic, v20 refs
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_latest_obs_v20 AS
WITH eligible AS (
    SELECT * FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v20
    WHERE is_eligible_for_run = 1
),
ranked_obs AS (
    SELECT
        e.run_id,
        e.HYBRID_MODEL_KEY_3T,
        e.mtrl_num,
        b.cal_month_start_dt,
        b.contract_price,
        b.total_net_cos,
        b.total_sls_qty,
        b.wac_spread,
        ROW_NUMBER() OVER (
            PARTITION BY e.run_id, e.HYBRID_MODEL_KEY_3T, e.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS obs_rn
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v20 b
      ON e.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
     AND e.mtrl_num             = b.mtrl_num
     AND b.cal_month_start_dt  <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
)
SELECT
    run_id,
    HYBRID_MODEL_KEY_3T,
    mtrl_num,
    COUNT(DISTINCT cal_month_start_dt)          AS latest_6_observed_months,
    NULLIF(SUM(total_net_cos), 0)
        / NULLIF(SUM(total_sls_qty), 0)         AS latest_6_observed_avg_contract_price,
    AVG(wac_spread)                             AS latest_6_observed_avg_wac_spread
FROM ranked_obs
WHERE obs_rn <= 6
GROUP BY run_id, HYBRID_MODEL_KEY_3T, mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 5 (BT): MATERIAL ASSUMPTIONS — unchanged logic, v20 refs
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v20 AS
WITH eligible AS (
    SELECT * FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v20
    WHERE is_eligible_for_run = 1
),
recent_6m AS (
    SELECT
        e.run_id,
        e.HYBRID_MODEL_KEY_3T,
        e.mtrl_num,
        la.anchor_month,
        COUNT(DISTINCT CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(la.anchor_month, -6)
            THEN b.cal_month_start_dt END)                  AS recent_6m_months,
        NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(la.anchor_month, -6)
            THEN b.total_net_cos END), 0)
        / NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(la.anchor_month, -6)
            THEN b.total_sls_qty END), 0)                   AS recent_6m_avg_contract_price
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v20 la
      ON e.run_id              = la.run_id
     AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
     AND e.mtrl_num             = la.mtrl_num
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v20 b
      ON e.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
     AND e.mtrl_num             = b.mtrl_num
     AND b.cal_month_start_dt  <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
    GROUP BY e.run_id, e.HYBRID_MODEL_KEY_3T, e.mtrl_num, la.anchor_month
)
SELECT
    e.run_id,
    e.HYBRID_MODEL_KEY_3T,
    e.mtrl_num,
    la.anchor_month,
    la.anchor_contract_price,
    la.anchor_wac_weighted,
    la.anchor_wac_spread,

    r6.recent_6m_months,
    lo.latest_6_observed_months,
    r6.recent_6m_avg_contract_price,
    lo.latest_6_observed_avg_contract_price,

    -- Pass through trend assumptions from the global step 4 table
    ma.forecast_start_contract_price,
    ma.forecast_start_wac_spread,
    ma.forecast_start_price_source,
    ma.sparse_price_confidence,
    ma.is_sparse_price_flag,
    ma.expected_monthly_trend_pct,
    ma.assigned_trend_method,

    CASE
        WHEN lo.latest_6_observed_months >= 6  THEN 'PRICE_6MO_AVG'
        WHEN lo.latest_6_observed_months >= 3  THEN 'PRICE_3_TO_5_MO_AVG'
        WHEN lo.latest_6_observed_months >= 1  THEN 'PRICE_LAST_OBSERVED'
        ELSE 'NO_PRICE_AVAILABLE'
    END AS sparse_price_confidence_bt,

    CASE
        WHEN lo.latest_6_observed_months < 6 THEN 1
        ELSE 0
    END AS is_sparse_price_flag_bt

FROM eligible e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v20 la
  ON e.run_id              = la.run_id
 AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = la.mtrl_num
LEFT JOIN recent_6m r6
  ON e.run_id              = r6.run_id
 AND e.HYBRID_MODEL_KEY_3T = r6.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = r6.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_latest_obs_v20 lo
  ON e.run_id              = lo.run_id
 AND e.HYBRID_MODEL_KEY_3T = lo.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = lo.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v20 ma
  ON e.HYBRID_MODEL_KEY_3T = ma.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = ma.mtrl_num
WHERE e.is_eligible_for_run = 1
;


/* ---------------------------------------------------------------------
   STEP 6: RUN-RESOLVED ASSUMPTIONS — unchanged logic, v20 refs
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v20 AS
SELECT
    e.run_id,
    e.jump_off_month,
    e.history_start_dt,
    e.history_end_dt,

    e.HYBRID_MODEL_KEY_3T,
    e.mtrl_num,

    e.MODEL_TIER,
    e.sap_months,
    e.l2_months,

    e.cust_segment,
    e.acct_classification,
    e.cust_prod_category,

    e.national_grp_id,
    e.national_grp_desc,

    e.mtrl_nme_nvgton,
    e.ndc_num,
    e.product_family,
    e.therapeutic_class,
    e.manufacturer_id,
    e.manufacturer_name,
    e.final_product_group,
    e.final_product_group_level,
    e.WAC,
    e.Total_Net_Revenue,
    e.top_100_brand_flag,
    e.brand_wac_rank,

    e.first_month,
    la.anchor_month,
    CAST(months_between(e.jump_off_month, e.first_month) AS INT) AS months_since_first_asof_jumpoff,

    la.anchor_contract_price,
    la.anchor_wac_weighted,
    la.anchor_wac_spread,
    la.anchor_total_sls_qty,
    la.anchor_total_net_cos,

    ma.forecast_start_contract_price,
    ma.forecast_start_wac_spread,
    ma.forecast_start_price_source,
    ma.sparse_price_confidence,
    ma.is_sparse_price_flag,

    ma.recent_6m_months,
    ma.latest_6_observed_months,

    ma.expected_monthly_trend_pct   AS resolved_monthly_trend_pct,
    ma.assigned_trend_method        AS trend_source

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v20 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v20 la
  ON e.run_id              = la.run_id
 AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = la.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v20 ma
  ON e.run_id              = ma.run_id
 AND e.HYBRID_MODEL_KEY_3T = ma.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = ma.mtrl_num
WHERE e.is_eligible_for_run = 1
  AND la.anchor_contract_price IS NOT NULL
;


/* ---------------------------------------------------------------------
   STEP 7: FUTURE ACTUAL MONTHS
   ---------------------------------------------------------------------
   Changed from v18: source is now the full base table with no flag
   filter. All actual months (including training-excluded rows) are
   included so step 5b can evaluate forecasts against the full actual
   universe. Actuals quality gate (exclude_from_actuals_flag = 0)
   is applied in step 5b at join time.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v20 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.HYBRID_MODEL_KEY_3T,
    ra.mtrl_num,
    b.cal_month_start_dt                                AS forecast_month,
    CAST(months_between(b.cal_month_start_dt, ra.jump_off_month) AS INT) + 1
                                                        AS forecast_horizon_month_num,
    DATE_FORMAT(b.cal_month_start_dt, 'yyyy-MM')        AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v20 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v20 b
  ON ra.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = b.mtrl_num
 AND b.cal_month_start_dt >= ra.jump_off_month
 AND b.cal_month_start_dt <  ADD_MONTHS(ra.jump_off_month, 60)
;


/* ---------------------------------------------------------------------
   STEP 8: FORECASTED CONTRACT PRICE — unchanged logic, v20 refs
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v20 AS
SELECT
    ra.run_id,
    ra.jump_off_month,
    ra.history_start_dt,
    ra.history_end_dt,

    ra.HYBRID_MODEL_KEY_3T,
    ra.mtrl_num,

    ra.MODEL_TIER,
    ra.sap_months,
    ra.l2_months,

    ra.cust_segment,
    ra.acct_classification,
    ra.cust_prod_category,

    ra.national_grp_id,
    ra.national_grp_desc,

    ra.mtrl_nme_nvgton,
    ra.ndc_num,
    ra.product_family,
    ra.therapeutic_class,
    ra.manufacturer_id,
    ra.manufacturer_name,
    ra.final_product_group,
    ra.final_product_group_level,
    src.WAC,
    src.total_net_revenue,
    ra.top_100_brand_flag,
    ra.brand_wac_rank,

    ra.first_month,
    ra.anchor_month,
    ra.months_since_first_asof_jumpoff,

    ra.anchor_contract_price,
    ra.anchor_wac_weighted,
    ra.anchor_wac_spread,

    ra.forecast_start_contract_price,
    ra.forecast_start_wac_spread,
    ra.forecast_start_price_source,
    ra.sparse_price_confidence,
    ra.is_sparse_price_flag,

    ra.recent_6m_months,
    ra.latest_6_observed_months,

    ra.resolved_monthly_trend_pct,
    ra.trend_source,

    fam.forecast_month,
    fam.forecast_horizon_month_num,
    fam.forecast_year_month,

    CASE
        WHEN ra.forecast_start_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ra.forecast_start_contract_price * POWER(
                1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                CEIL(fam.forecast_horizon_month_num / 3.0)
            ),
            0
        )
    END                                                 AS forecasted_contract_price

FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v20 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v20 fam
  ON ra.run_id              = fam.run_id
 AND ra.HYBRID_MODEL_KEY_3T = fam.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = fam.mtrl_num
LEFT JOIN (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(WAC)               AS WAC,
        MAX(TOTAL_NET_REVENUE) AS total_net_revenue
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v20
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num
) src
  ON ra.HYBRID_MODEL_KEY_3T = src.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = src.mtrl_num
;