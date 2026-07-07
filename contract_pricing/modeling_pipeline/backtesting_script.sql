/* =====================================================================
   CONTRACT PRICE BACKTEST PIPELINE (v10)
   ---------------------------------------------------------------------
   DESIGN GOALS
   - Rolling-origin backtesting
   - Monthly forecast frequency
   - 5-year forward horizon (60 months)
   - 1:1 unique evaluation grain:
       run_id + HYBRID_MODEL_KEY_3T + mtrl_num + forecast_month
   - Simple / explainable v10 baseline
   - Three-tier granularity: SAP_CUST -> L2 -> NATIONAL_GRP_FALLBACK
   - Trend = 0 for all series; price anchor uses prior/observed avg logic
   - Uses actual qty for dollar-error evaluation
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: BACKTEST RUNS
   - Same jump-off points as WAC pipeline
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_runs_v10 AS
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
   - One row per HYBRID_MODEL_KEY_3T + material series
   - Used for run eligibility and diagnostics
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v10 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10
),
ranked AS (
    SELECT
        b.*,
        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt ASC
        ) AS rn_first,
        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn_last
    FROM base b
),
first_row AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        cal_month_start_dt  AS first_month,
        contract_price      AS first_contract_price
    FROM ranked
    WHERE rn_first = 1
),
last_row AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        cal_month_start_dt  AS last_actual_month,
        contract_price      AS last_actual_contract_price,
        wac_weighted        AS last_actual_wac_weighted,
        wac_spread          AS last_actual_wac_spread
    FROM ranked
    WHERE rn_last = 1
),
agg AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,

        -- tier metadata
        MAX(MODEL_TIER)                 AS MODEL_TIER,
        MAX(sap_months)                 AS sap_months,
        MAX(l2_months)                  AS l2_months,

        -- backward-compatible descriptor
        MAX(customer_group_key_id)      AS customer_group_key_id,
        MAX(customer_group_key_desc)    AS customer_group_key_desc,

        MAX(cust_segment)               AS cust_segment,
        MAX(acct_classification)        AS acct_classification,
        MAX(cust_prod_category)         AS cust_prod_category,

        MAX(national_grp_id)            AS national_grp_id,
        MAX(national_grp_desc)          AS national_grp_desc,

        MAX(mtrl_nme_nvgton)            AS mtrl_nme_nvgton,
        MAX(ndc_num)                    AS ndc_num,

        MAX(product_family)             AS product_family,
        MAX(therapeutic_class)          AS therapeutic_class,
        MAX(manufacturer_id)            AS manufacturer_id,
        MAX(manufacturer_name)          AS manufacturer_name,
        MAX(final_product_group)        AS final_product_group,
        MAX(final_product_group_level)  AS final_product_group_level,

        COUNT(DISTINCT cal_month_start_dt) AS total_months_all_time
    FROM base
    GROUP BY
        HYBRID_MODEL_KEY_3T,
        mtrl_num
)
SELECT
    a.*,
    f.first_month,
    l.last_actual_month,
    f.first_contract_price,
    l.last_actual_contract_price,
    l.last_actual_wac_weighted,
    l.last_actual_wac_spread
FROM agg a
LEFT JOIN first_row f
  ON a.HYBRID_MODEL_KEY_3T = f.HYBRID_MODEL_KEY_3T
 AND a.mtrl_num = f.mtrl_num
LEFT JOIN last_row l
  ON a.HYBRID_MODEL_KEY_3T = l.HYBRID_MODEL_KEY_3T
 AND a.mtrl_num = l.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 2: RUN ELIGIBILITY
   - Eligible if series existed on or before run history_end_dt
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v10 AS
SELECT
    r.run_id,
    r.jump_off_month,
    r.lookback_years,
    r.history_start_dt,
    r.history_end_dt,

    sp.HYBRID_MODEL_KEY_3T,
    sp.mtrl_num,

    -- tier metadata
    sp.MODEL_TIER,
    sp.sap_months,
    sp.l2_months,

    -- backward-compatible descriptor
    sp.customer_group_key_id,
    sp.customer_group_key_desc,

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

    sp.first_month,
    sp.last_actual_month,

    CASE
        WHEN sp.first_month IS NOT NULL
         AND sp.first_month <= r.history_end_dt
        THEN 1 ELSE 0
    END AS is_eligible_for_run,

    CASE
        WHEN sp.first_month IS NULL            THEN 'NO_HISTORY'
        WHEN sp.first_month > r.history_end_dt THEN 'NOT_LAUNCHED_YET'
        ELSE 'ELIGIBLE'
    END AS data_coverage_flag

FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v10 r
CROSS JOIN uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v10 sp
;


/* ---------------------------------------------------------------------
   STEP 3: RUN-SPECIFIC LAST ACTUAL (RAW)
   - Anchor comes from raw base table, not training-clean
   - Uses latest observed month <= history_end_dt
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v10 AS
WITH eligible AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v10
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
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10 b
      ON e.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
     AND e.mtrl_num = b.mtrl_num
     AND b.cal_month_start_dt <= e.history_end_dt
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
   STEP 4: RUN-SPECIFIC CLEAN HIST PANEL
   - Historical panel used for model fitting only
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v10 AS
SELECT
    e.run_id,
    e.jump_off_month,
    e.lookback_years,
    e.history_start_dt,
    e.history_end_dt,

    e.HYBRID_MODEL_KEY_3T,
    e.mtrl_num,

    e.MODEL_TIER,
    e.sap_months,
    e.l2_months,

    e.customer_group_key_id,
    e.customer_group_key_desc,

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

    t.cal_month_start_dt,
    t.total_net_cos,
    t.total_sls_qty,
    t.contract_price,
    t.wac_weighted,
    t.wac_spread,
    t.mom_contract_price_change_pct,
    t.contract_price_change_outlier_flag,
    t.series_month_index,
    t.series_valid_month_count,
    t.sap_to_l2_coverage_ratio

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v10 e
JOIN uspd_analytics_den.analytics_gold.contract_price_training_clean_v10 t
  ON e.HYBRID_MODEL_KEY_3T = t.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num = t.mtrl_num
 AND t.cal_month_start_dt >= e.history_start_dt
 AND t.cal_month_start_dt <= e.history_end_dt
WHERE
    e.is_eligible_for_run = 1
    AND t.include_for_modeling_flag = 1
;


/* ---------------------------------------------------------------------
   STEP 5: RUN MATERIAL-LEVEL ASSUMPTIONS
   - Aligns with v10 price logic: no trend, price fallback hierarchy
   - Prior 12m avg (>=6 months) -> latest 12 observed avg (>=6) -> anchor
   - Trend = 0 for all series
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v10 AS
WITH last_hist_month AS (
    SELECT
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(cal_month_start_dt) AS anchor_month
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v10
    GROUP BY
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num
),

-- calendar-window stats: recent 12m and prior 12m relative to anchor
calendar_window_agg AS (
    SELECT
        lhm.run_id,
        lhm.HYBRID_MODEL_KEY_3T,
        lhm.mtrl_num,
        lhm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.cal_month_start_dt
        END)                                            AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -24)
             AND h.cal_month_start_dt <= ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.cal_month_start_dt
        END)                                            AS prior_12m_months,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.contract_price
        END)                                            AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -24)
             AND h.cal_month_start_dt <= ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.contract_price
        END)                                            AS prior_12m_avg_contract_price,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.wac_spread
        END)                                            AS recent_12m_avg_wac_spread,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -24)
             AND h.cal_month_start_dt <= ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.wac_spread
        END)                                            AS prior_12m_avg_wac_spread

    FROM last_hist_month lhm
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v10 h
      ON lhm.run_id             = h.run_id
     AND lhm.HYBRID_MODEL_KEY_3T = h.HYBRID_MODEL_KEY_3T
     AND lhm.mtrl_num            = h.mtrl_num
    GROUP BY
        lhm.run_id,
        lhm.HYBRID_MODEL_KEY_3T,
        lhm.mtrl_num,
        lhm.anchor_month
),

-- latest 12 observed months regardless of calendar window
ranked_history AS (
    SELECT
        h.*,
        ROW_NUMBER() OVER (
            PARTITION BY h.run_id, h.HYBRID_MODEL_KEY_3T, h.mtrl_num
            ORDER BY h.cal_month_start_dt DESC
        ) AS history_rn
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v10 h
),
latest_12_observed_agg AS (
    SELECT
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        COUNT(DISTINCT cal_month_start_dt)              AS latest_12_observed_months,
        AVG(contract_price)                             AS latest_12_observed_avg_contract_price,
        AVG(wac_spread)                                 AS latest_12_observed_avg_wac_spread,
        MIN(cal_month_start_dt)                         AS latest_12_observed_start_month,
        MAX(cal_month_start_dt)                         AS latest_12_observed_end_month
    FROM ranked_history
    WHERE history_rn <= 12
    GROUP BY
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num
)

SELECT
    cwa.run_id,
    cwa.HYBRID_MODEL_KEY_3T,
    cwa.mtrl_num,
    cwa.anchor_month,

    cwa.recent_12m_months,
    cwa.prior_12m_months,
    cwa.recent_12m_avg_contract_price,
    cwa.prior_12m_avg_contract_price,
    cwa.recent_12m_avg_wac_spread,
    cwa.prior_12m_avg_wac_spread,

    l12.latest_12_observed_months,
    l12.latest_12_observed_avg_contract_price,
    l12.latest_12_observed_avg_wac_spread,
    l12.latest_12_observed_start_month,
    l12.latest_12_observed_end_month,

    -- =====================================================
    -- Forecast start contract price
    -- Rule:
    -- 1. Prior 12m >= 6 months -> prior 12m avg
    -- 2. >= 6 observed months  -> latest observed avg
    -- 3. < 6 observed months   -> anchor (last raw price)
    -- =====================================================
    CASE
        WHEN cwa.prior_12m_months >= 6
         AND cwa.prior_12m_avg_contract_price IS NOT NULL
         AND cwa.prior_12m_avg_contract_price > 0
        THEN cwa.prior_12m_avg_contract_price

        WHEN l12.latest_12_observed_months >= 12
        THEN l12.latest_12_observed_avg_contract_price

        ELSE la.anchor_contract_price
    END                                                 AS forecast_start_contract_price,

    -- =====================================================
    -- Forecast start WAC spread (mirrors price logic)
    -- =====================================================
    CASE
        WHEN cwa.prior_12m_months >= 6
         AND cwa.prior_12m_avg_wac_spread IS NOT NULL
        THEN cwa.prior_12m_avg_wac_spread

        WHEN l12.latest_12_observed_months >= 6
        THEN l12.latest_12_observed_avg_wac_spread

        ELSE la.anchor_wac_spread
    END                                                 AS forecast_start_wac_spread,

    -- =====================================================
    -- Trend = 0 for all series (v10 design)
    -- =====================================================
    0                                                   AS monthly_trend_pct_raw,
    0                                                   AS expected_monthly_trend_pct,

    -- =====================================================
    -- Price source label for QA / explainability
    -- =====================================================
    CASE
        WHEN cwa.prior_12m_months >= 6
         AND cwa.prior_12m_avg_contract_price IS NOT NULL
         AND cwa.prior_12m_avg_contract_price > 0
          AND (
        la.anchor_wac_spread IS NULL
            OR cwa.prior_12m_avg_wac_spread IS NULL
            OR (la.anchor_wac_spread - cwa.prior_12m_avg_wac_spread) > -0.30
            )
        AND cwa.recent_12m_avg_contract_price / NULLIF(cwa.prior_12m_avg_contract_price, 0) >= 0.40
        AND la.anchor_contract_price / NULLIF(cwa.prior_12m_avg_contract_price, 0) >= 0.15
        THEN 'AVG_PRIOR_12M_NO_TREND'

        WHEN l12.latest_12_observed_months >= 12
        THEN 'AVG_LATEST_12_OBSERVED_MONTHS_NO_TREND'

        -- WHEN l12.latest_12_observed_months >= 6
        -- THEN 'AVG_6_TO_11_OBSERVED_MONTHS_NO_TREND'

        WHEN l12.latest_12_observed_months > 0
        THEN 'LATEST_PRICE_LT_12_OBSERVED_MONTHS_NO_TREND'

        ELSE 'NO_HISTORY_AVAILABLE'
    END                                                 AS forecast_start_price_source,

    -- sparse confidence flag
    CASE
        WHEN l12.latest_12_observed_months >= 6  THEN 'PRICE_6MO_AVG'
        WHEN l12.latest_12_observed_months >= 3  THEN 'PRICE_3_TO_5_MO_AVG'
        WHEN l12.latest_12_observed_months >= 1  THEN 'PRICE_LAST_OBSERVED'
        ELSE                                          'NO_PRICE_AVAILABLE'
    END                                                 AS sparse_price_confidence,

    CASE
        WHEN l12.latest_12_observed_months < 6   THEN 1
        ELSE                                          0
    END                                                 AS is_sparse_price_flag

FROM calendar_window_agg cwa
LEFT JOIN latest_12_observed_agg l12
  ON cwa.run_id              = l12.run_id
 AND cwa.HYBRID_MODEL_KEY_3T = l12.HYBRID_MODEL_KEY_3T
 AND cwa.mtrl_num             = l12.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v10 la
  ON cwa.run_id              = la.run_id
 AND cwa.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND cwa.mtrl_num             = la.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 6: RUN-RESOLVED ASSUMPTIONS
   - Anchor = latest raw actual before jump-off
   - Trend = 0 for all series (v10 design)
   - Price comes from material assumptions step only
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v10 AS
SELECT
    e.run_id,
    e.jump_off_month,
    e.history_start_dt,
    e.history_end_dt,

    e.HYBRID_MODEL_KEY_3T,
    e.mtrl_num,

    -- tier metadata
    e.MODEL_TIER,
    e.sap_months,
    e.l2_months,

    -- backward-compatible descriptor
    e.customer_group_key_id,
    e.customer_group_key_desc,

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

    e.first_month,
    la.anchor_month,
    CAST(months_between(e.jump_off_month, e.first_month) AS INT) AS months_since_first_asof_jumpoff,

    la.anchor_contract_price,
    la.anchor_wac_weighted,
    la.anchor_wac_spread,
    la.anchor_total_sls_qty,
    la.anchor_total_net_cos,

    -- resolved forecast start price from material assumptions
    ma.forecast_start_contract_price,
    ma.forecast_start_wac_spread,
    ma.forecast_start_price_source,
    ma.sparse_price_confidence,
    ma.is_sparse_price_flag,

    -- diagnostic history stats
    ma.recent_12m_months,
    ma.prior_12m_months,
    ma.latest_12_observed_months,

    -- trend = 0 for all (v10 design)
    0                                                   AS resolved_monthly_trend_pct,
    'STATIC_NO_TREND'                                   AS trend_source

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v10 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v10 la
  ON e.run_id              = la.run_id
 AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = la.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v10 ma
  ON e.run_id              = ma.run_id
 AND e.HYBRID_MODEL_KEY_3T = ma.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = ma.mtrl_num
WHERE
    e.is_eligible_for_run = 1
    AND la.anchor_contract_price IS NOT NULL
;


/* ---------------------------------------------------------------------
   STEP 7: FUTURE ACTUAL MONTHS FOR BACKTEST
   - Uses actual observed months after jump-off
   - Limited to 60 months forward
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v10 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.HYBRID_MODEL_KEY_3T,
    ra.mtrl_num,
    b.cal_month_start_dt                                AS forecast_month,
    CAST(months_between(b.cal_month_start_dt, ra.jump_off_month) AS INT) + 1
                                                        AS forecast_horizon_month_num,
    DATE_FORMAT(b.cal_month_start_dt, 'yyyy-MM')        AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v10 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10 b
  ON ra.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = b.mtrl_num
 AND b.cal_month_start_dt >= ra.jump_off_month
 AND b.cal_month_start_dt <  ADD_MONTHS(ra.jump_off_month, 60)
;


/* ---------------------------------------------------------------------
   STEP 8: FORECASTED CONTRACT PRICE
   - Forecast from forecast_start_contract_price using 0 trend
   - forecast_start_contract_price replaces anchor_contract_price
     as the starting point; trend compounds from there
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v10 AS
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

    ra.customer_group_key_id,
    ra.customer_group_key_desc,

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

    ra.recent_12m_months,
    ra.prior_12m_months,
    ra.latest_12_observed_months,

    ra.resolved_monthly_trend_pct,
    ra.trend_source,

    fam.forecast_month,
    fam.forecast_horizon_month_num,
    fam.forecast_year_month,

    -- forecast compounds from forecast_start_contract_price with 0 trend
    -- GREATEST guards against negative values from floating point
    CASE
        WHEN ra.forecast_start_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ra.forecast_start_contract_price * POWER(
                1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                fam.forecast_horizon_month_num
            ),
            0
        )
    END                                                 AS forecasted_contract_price

FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v10 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v10 fam
  ON ra.run_id              = fam.run_id
 AND ra.HYBRID_MODEL_KEY_3T = fam.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = fam.mtrl_num
;


-- /* ---------------------------------------------------------------------
--    STEP 9: EVALUATION DETAIL
--    - Compares forecast vs actual contract price
--    - Uses actual qty to compute dollar error
--    --------------------------------------------------------------------- */
-- CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v10 AS
-- WITH joined AS (
--     SELECT
--         f.run_id,
--         f.jump_off_month,
--         f.HYBRID_MODEL_KEY_3T,
--         f.mtrl_num,
--         f.forecast_month,
--         f.forecast_horizon_month_num,
--         f.forecast_year_month,

--         f.MODEL_TIER,
--         f.sap_months,
--         f.l2_months,
--         f.sparse_price_confidence,
--         f.is_sparse_price_flag,

--         f.customer_group_key_id,
--         f.customer_group_key_desc,

--         f.cust_segment,
--         f.acct_classification,
--         f.cust_prod_category,

--         f.national_grp_id,
--         f.national_grp_desc,

--         f.mtrl_nme_nvgton,
--         f.ndc_num,
--         f.product_family,
--         f.therapeutic_class,
--         f.manufacturer_id,
--         f.manufacturer_name,
--         f.final_product_group,
--         f.final_product_group_level,

--         f.first_month,
--         f.anchor_month,
--         f.months_since_first_asof_jumpoff,

--         f.anchor_contract_price,
--         f.anchor_wac_weighted,
--         f.anchor_wac_spread,

--         f.forecast_start_contract_price,
--         f.forecast_start_price_source,

--         f.resolved_monthly_trend_pct,
--         f.trend_source,
--         f.forecasted_contract_price,

--         f.recent_12m_months,
--         f.prior_12m_months,
--         f.latest_12_observed_months,

--         a.contract_price        AS actual_contract_price,
--         a.account_class_cd      AS account_class_cd,
--         a.wac_weighted          AS actual_wac_weighted,
--         a.wac_spread            AS actual_wac_spread,
--         a.total_sls_qty         AS actual_sls_qty,
--         a.total_net_cos         AS actual_net_cos
--     FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v10 f
--     LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10 a
--       ON f.HYBRID_MODEL_KEY_3T = a.HYBRID_MODEL_KEY_3T
--      AND f.mtrl_num             = a.mtrl_num
--      AND f.forecast_month       = a.cal_month_start_dt
-- ),
-- calc AS (
--     SELECT
--         j.*,

--         -- dollars using actual qty to isolate price forecast error
--         j.forecasted_contract_price * j.actual_sls_qty  AS forecasted_dollars,
--         j.actual_contract_price * j.actual_sls_qty      AS actual_dollars,

--         -- price error
--         (j.forecasted_contract_price - j.actual_contract_price)
--                                                         AS error_contract_price,
--         ABS(j.forecasted_contract_price - j.actual_contract_price)
--                                                         AS ae_contract_price,

--         CASE
--             WHEN j.actual_contract_price IS NOT NULL
--              AND j.actual_contract_price <> 0
--             THEN (j.forecasted_contract_price - j.actual_contract_price)
--                  / j.actual_contract_price
--         END                                             AS bias_contract_price,

--         CASE
--             WHEN j.actual_contract_price IS NOT NULL
--              AND j.actual_contract_price <> 0
--             THEN ABS(j.forecasted_contract_price - j.actual_contract_price)
--                  / ABS(j.actual_contract_price)
--         END                                             AS ape_contract_price,

--         -- dollar error
--         (j.forecasted_contract_price * j.actual_sls_qty)
--             - (j.actual_contract_price * j.actual_sls_qty)
--                                                         AS error_dollars,
--         ABS(
--             (j.forecasted_contract_price * j.actual_sls_qty)
--             - (j.actual_contract_price * j.actual_sls_qty)
--         )                                               AS ae_dollars,

--         CASE
--             WHEN (j.actual_contract_price * j.actual_sls_qty) IS NOT NULL
--              AND (j.actual_contract_price * j.actual_sls_qty) <> 0
--             THEN (
--                 (j.forecasted_contract_price * j.actual_sls_qty)
--                 - (j.actual_contract_price * j.actual_sls_qty)
--             ) / (j.actual_contract_price * j.actual_sls_qty)
--         END                                             AS bias_dollars,

--         CASE
--             WHEN (j.actual_contract_price * j.actual_sls_qty) IS NOT NULL
--              AND (j.actual_contract_price * j.actual_sls_qty) <> 0
--             THEN ABS(
--                 (j.forecasted_contract_price * j.actual_sls_qty)
--                 - (j.actual_contract_price * j.actual_sls_qty)
--             ) / ABS(j.actual_contract_price * j.actual_sls_qty)
--         END                                             AS ape_dollars,

--         -- implied spread from forecast using actual WAC
--         CASE
--             WHEN j.actual_wac_weighted IS NOT NULL
--              AND j.actual_wac_weighted <> 0
--             THEN (j.forecasted_contract_price / j.actual_wac_weighted) - 1
--         END                                             AS implied_forecast_wac_spread

--     FROM joined j
-- ),
-- weighted AS (
--     SELECT
--         c.*,

--         CASE
--             WHEN SUM(ABS(c.error_dollars)) OVER (PARTITION BY c.run_id) <> 0
--             THEN ABS(c.error_dollars)
--                  / SUM(ABS(c.error_dollars)) OVER (PARTITION BY c.run_id)
--         END                                             AS weighted_percent_error,

--         CASE
--             WHEN SUM(ABS(c.actual_dollars)) OVER (PARTITION BY c.run_id) <> 0
--             THEN ABS(c.actual_dollars)
--                  / SUM(ABS(c.actual_dollars)) OVER (PARTITION BY c.run_id)
--         END                                             AS revenue_share

--     FROM calc c
-- ),
-- ranked AS (
--     SELECT
--         w.*,
--         NTILE(5) OVER (
--             PARTITION BY w.run_id
--             ORDER BY ABS(w.actual_dollars) DESC NULLS LAST
--         ) AS revenue_quintile_desc
--     FROM weighted w
-- )
-- SELECT
--     r.*,

--     CASE
--         WHEN r.revenue_quintile_desc = 1         THEN 'TOP_20'
--         WHEN r.revenue_quintile_desc IN (2,3,4)  THEN 'MIDDLE_60'
--         WHEN r.revenue_quintile_desc = 5         THEN 'BOTTOM_20'
--         ELSE 'UNKNOWN'
--     END                                                 AS materiality_band,

--     CASE
--         WHEN r.revenue_quintile_desc = 1         THEN 0.03
--         WHEN r.revenue_quintile_desc IN (2,3,4)  THEN 0.10
--         WHEN r.revenue_quintile_desc = 5         THEN 0.20
--         ELSE NULL
--     END                                                 AS materiality_threshold_pct,

--     CASE
--         WHEN r.ape_contract_price IS NOT NULL
--          AND r.ape_contract_price < 0.20 THEN 1
--         WHEN r.ape_contract_price IS NOT NULL    THEN 0
--         ELSE NULL
--     END                                                 AS pass_flag_vs_actual_error_threshold,

--     CASE
--         WHEN r.ape_dollars IS NOT NULL
--          AND (
--                 (r.revenue_quintile_desc = 1        AND r.ape_dollars <= 0.03) OR
--                 (r.revenue_quintile_desc IN (2,3,4) AND r.ape_dollars <= 0.10) OR
--                 (r.revenue_quintile_desc = 5        AND r.ape_dollars <= 0.20)
--              )
--         THEN 1
--         WHEN r.ape_dollars IS NOT NULL           THEN 0
--         ELSE NULL
--     END                                                 AS pass_flag_vs_materiality_threshold,

--     CASE
--         WHEN r.ape_dollars IS NOT NULL
--          AND (
--                 (r.revenue_quintile_desc = 1        AND r.ape_dollars > 0.03) OR
--                 (r.revenue_quintile_desc IN (2,3,4) AND r.ape_dollars > 0.10) OR
--                 (r.revenue_quintile_desc = 5        AND r.ape_dollars > 0.20)
--              )
--          AND ABS(r.actual_dollars) IS NOT NULL
--          AND ABS(r.actual_dollars) > 0
--         THEN 'CRITICAL'
--         WHEN r.ape_contract_price IS NOT NULL
--          AND r.ape_contract_price > 0.20         THEN 'MODERATE'
--         ELSE 'PASS'
--     END                                                 AS review_priority,

--     CASE
--         WHEN r.forecasted_contract_price > 3 * r.anchor_contract_price THEN 1
--         ELSE 0
--     END                                                 AS forecast_explosion_flag

-- FROM ranked r
-- WHERE forecast_month IS NOT NULL
-- ;


/* =====================================================================
   CONTRACT PRICE BACKTEST PIPELINE (v10)
   ---------------------------------------------------------------------
   DESIGN GOALS
   - Rolling-origin backtesting
   - Monthly forecast frequency
   - 5-year forward horizon (60 months)
   - 1:1 unique evaluation grain:
       run_id + HYBRID_MODEL_KEY_3T + mtrl_num + forecast_month
   - Simple / explainable v10 baseline
   - Three-tier granularity: SAP_CUST -> L2 -> NATIONAL_GRP_FALLBACK
   - Trend = 0 for all series; price anchor uses prior/observed avg logic
   - Uses actual qty for dollar-error evaluation
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: BACKTEST RUNS
   - Same jump-off points as WAC pipeline
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_runs_v10 AS
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
   - One row per HYBRID_MODEL_KEY_3T + material series
   - Used for run eligibility and diagnostics
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v10 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10
),
ranked AS (
    SELECT
        b.*,
        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt ASC
        ) AS rn_first,
        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn_last
    FROM base b
),
first_row AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        cal_month_start_dt  AS first_month,
        contract_price      AS first_contract_price
    FROM ranked
    WHERE rn_first = 1
),
last_row AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        cal_month_start_dt  AS last_actual_month,
        contract_price      AS last_actual_contract_price,
        wac_weighted        AS last_actual_wac_weighted,
        wac_spread          AS last_actual_wac_spread
    FROM ranked
    WHERE rn_last = 1
),
agg AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,

        -- tier metadata
        MAX(MODEL_TIER)                 AS MODEL_TIER,
        MAX(sap_months)                 AS sap_months,
        MAX(l2_months)                  AS l2_months,

        -- backward-compatible descriptor
        MAX(customer_group_key_id)      AS customer_group_key_id,
        MAX(customer_group_key_desc)    AS customer_group_key_desc,

        MAX(cust_segment)               AS cust_segment,
        MAX(acct_classification)        AS acct_classification,
        MAX(cust_prod_category)         AS cust_prod_category,

        MAX(national_grp_id)            AS national_grp_id,
        MAX(national_grp_desc)          AS national_grp_desc,

        MAX(mtrl_nme_nvgton)            AS mtrl_nme_nvgton,
        MAX(ndc_num)                    AS ndc_num,

        MAX(product_family)             AS product_family,
        MAX(therapeutic_class)          AS therapeutic_class,
        MAX(manufacturer_id)            AS manufacturer_id,
        MAX(manufacturer_name)          AS manufacturer_name,
        MAX(final_product_group)        AS final_product_group,
        MAX(final_product_group_level)  AS final_product_group_level,

        COUNT(DISTINCT cal_month_start_dt) AS total_months_all_time
    FROM base
    GROUP BY
        HYBRID_MODEL_KEY_3T,
        mtrl_num
)
SELECT
    a.*,
    f.first_month,
    l.last_actual_month,
    f.first_contract_price,
    l.last_actual_contract_price,
    l.last_actual_wac_weighted,
    l.last_actual_wac_spread
FROM agg a
LEFT JOIN first_row f
  ON a.HYBRID_MODEL_KEY_3T = f.HYBRID_MODEL_KEY_3T
 AND a.mtrl_num = f.mtrl_num
LEFT JOIN last_row l
  ON a.HYBRID_MODEL_KEY_3T = l.HYBRID_MODEL_KEY_3T
 AND a.mtrl_num = l.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 2: RUN ELIGIBILITY
   - Eligible if series existed on or before run history_end_dt
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v10 AS
SELECT
    r.run_id,
    r.jump_off_month,
    r.lookback_years,
    r.history_start_dt,
    r.history_end_dt,

    sp.HYBRID_MODEL_KEY_3T,
    sp.mtrl_num,

    -- tier metadata
    sp.MODEL_TIER,
    sp.sap_months,
    sp.l2_months,

    -- backward-compatible descriptor
    sp.customer_group_key_id,
    sp.customer_group_key_desc,

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

    sp.first_month,
    sp.last_actual_month,

    CASE
        WHEN sp.first_month IS NOT NULL
         AND sp.first_month <= r.history_end_dt
        THEN 1 ELSE 0
    END AS is_eligible_for_run,

    CASE
        WHEN sp.first_month IS NULL            THEN 'NO_HISTORY'
        WHEN sp.first_month > r.history_end_dt THEN 'NOT_LAUNCHED_YET'
        ELSE 'ELIGIBLE'
    END AS data_coverage_flag

FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v10 r
CROSS JOIN uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v10 sp
;


/* ---------------------------------------------------------------------
   STEP 3: RUN-SPECIFIC LAST ACTUAL (RAW)
   - Anchor comes from raw base table, not training-clean
   - Uses latest observed month <= history_end_dt
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v10 AS
WITH eligible AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v10
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
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10 b
      ON e.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
     AND e.mtrl_num = b.mtrl_num
     AND b.cal_month_start_dt <= e.history_end_dt
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
   STEP 4: RUN-SPECIFIC CLEAN HIST PANEL
   - Historical panel used for model fitting only
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v10 AS
SELECT
    e.run_id,
    e.jump_off_month,
    e.lookback_years,
    e.history_start_dt,
    e.history_end_dt,

    e.HYBRID_MODEL_KEY_3T,
    e.mtrl_num,

    e.MODEL_TIER,
    e.sap_months,
    e.l2_months,

    e.customer_group_key_id,
    e.customer_group_key_desc,

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

    t.cal_month_start_dt,
    t.total_net_cos,
    t.total_sls_qty,
    t.contract_price,
    t.wac_weighted,
    t.wac_spread,
    t.mom_contract_price_change_pct,
    t.contract_price_change_outlier_flag,
    t.series_month_index,
    t.series_valid_month_count,
    t.sap_to_l2_coverage_ratio

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v10 e
JOIN uspd_analytics_den.analytics_gold.contract_price_training_clean_v10 t
  ON e.HYBRID_MODEL_KEY_3T = t.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num = t.mtrl_num
 AND t.cal_month_start_dt >= e.history_start_dt
 AND t.cal_month_start_dt <= e.history_end_dt
WHERE
    e.is_eligible_for_run = 1
    AND t.include_for_modeling_flag = 1
;


/* ---------------------------------------------------------------------
   STEP 5: RUN MATERIAL-LEVEL ASSUMPTIONS
   - Aligns with v10 price logic: no trend, price fallback hierarchy
   - Prior 12m avg (>=6 months) -> latest 12 observed avg (>=6) -> anchor
   - Trend = 0 for all series
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v10 AS
WITH last_hist_month AS (
    SELECT
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(cal_month_start_dt) AS anchor_month
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v10
    GROUP BY
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num
),

-- calendar-window stats: recent 12m and prior 12m relative to anchor
calendar_window_agg AS (
    SELECT
        lhm.run_id,
        lhm.HYBRID_MODEL_KEY_3T,
        lhm.mtrl_num,
        lhm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.cal_month_start_dt
        END)                                            AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -24)
             AND h.cal_month_start_dt <= ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.cal_month_start_dt
        END)                                            AS prior_12m_months,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.contract_price
        END)                                            AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -24)
             AND h.cal_month_start_dt <= ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.contract_price
        END)                                            AS prior_12m_avg_contract_price,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.wac_spread
        END)                                            AS recent_12m_avg_wac_spread,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -24)
             AND h.cal_month_start_dt <= ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.wac_spread
        END)                                            AS prior_12m_avg_wac_spread

    FROM last_hist_month lhm
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v10 h
      ON lhm.run_id             = h.run_id
     AND lhm.HYBRID_MODEL_KEY_3T = h.HYBRID_MODEL_KEY_3T
     AND lhm.mtrl_num            = h.mtrl_num
    GROUP BY
        lhm.run_id,
        lhm.HYBRID_MODEL_KEY_3T,
        lhm.mtrl_num,
        lhm.anchor_month
),

-- latest 12 observed months regardless of calendar window
ranked_history AS (
    SELECT
        h.*,
        ROW_NUMBER() OVER (
            PARTITION BY h.run_id, h.HYBRID_MODEL_KEY_3T, h.mtrl_num
            ORDER BY h.cal_month_start_dt DESC
        ) AS history_rn
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v10 h
),
latest_12_observed_agg AS (
    SELECT
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        COUNT(DISTINCT cal_month_start_dt)              AS latest_12_observed_months,
        AVG(contract_price)                             AS latest_12_observed_avg_contract_price,
        AVG(wac_spread)                                 AS latest_12_observed_avg_wac_spread,
        MIN(cal_month_start_dt)                         AS latest_12_observed_start_month,
        MAX(cal_month_start_dt)                         AS latest_12_observed_end_month
    FROM ranked_history
    WHERE history_rn <= 12
    GROUP BY
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num
)

SELECT
    cwa.run_id,
    cwa.HYBRID_MODEL_KEY_3T,
    cwa.mtrl_num,
    cwa.anchor_month,

    cwa.recent_12m_months,
    cwa.prior_12m_months,
    cwa.recent_12m_avg_contract_price,
    cwa.prior_12m_avg_contract_price,
    cwa.recent_12m_avg_wac_spread,
    cwa.prior_12m_avg_wac_spread,

    l12.latest_12_observed_months,
    l12.latest_12_observed_avg_contract_price,
    l12.latest_12_observed_avg_wac_spread,
    l12.latest_12_observed_start_month,
    l12.latest_12_observed_end_month,

    -- =====================================================
    -- Forecast start contract price
    -- Rule:
    -- 1. Prior 12m >= 6 months -> prior 12m avg
    -- 2. >= 6 observed months  -> latest observed avg
    -- 3. < 6 observed months   -> anchor (last raw price)
    -- =====================================================
    CASE
        WHEN cwa.prior_12m_months >= 6
         AND cwa.prior_12m_avg_contract_price IS NOT NULL
         AND cwa.prior_12m_avg_contract_price > 0
        THEN cwa.prior_12m_avg_contract_price

        WHEN l12.latest_12_observed_months >= 12
        THEN l12.latest_12_observed_avg_contract_price

        ELSE la.anchor_contract_price
    END                                                 AS forecast_start_contract_price,

    -- =====================================================
    -- Forecast start WAC spread (mirrors price logic)
    -- =====================================================
    CASE
        WHEN cwa.prior_12m_months >= 6
         AND cwa.prior_12m_avg_wac_spread IS NOT NULL
        THEN cwa.prior_12m_avg_wac_spread

        WHEN l12.latest_12_observed_months >= 6
        THEN l12.latest_12_observed_avg_wac_spread

        ELSE la.anchor_wac_spread
    END                                                 AS forecast_start_wac_spread,

    -- =====================================================
    -- Trend = 0 for all series (v10 design)
    -- =====================================================
    0                                                   AS monthly_trend_pct_raw,
    0                                                   AS expected_monthly_trend_pct,

    -- =====================================================
    -- Price source label for QA / explainability
    -- =====================================================
    CASE
        WHEN cwa.prior_12m_months >= 6
         AND cwa.prior_12m_avg_contract_price IS NOT NULL
         AND cwa.prior_12m_avg_contract_price > 0
          AND (
        la.anchor_wac_spread IS NULL
            OR cwa.prior_12m_avg_wac_spread IS NULL
            OR (la.anchor_wac_spread - cwa.prior_12m_avg_wac_spread) > -0.30
            )
        AND cwa.recent_12m_avg_contract_price / NULLIF(cwa.prior_12m_avg_contract_price, 0) >= 0.40
        AND la.anchor_contract_price / NULLIF(cwa.prior_12m_avg_contract_price, 0) >= 0.15
        THEN 'AVG_PRIOR_12M_NO_TREND'

        WHEN l12.latest_12_observed_months >= 12
        THEN 'AVG_LATEST_12_OBSERVED_MONTHS_NO_TREND'

        -- WHEN l12.latest_12_observed_months >= 6
        -- THEN 'AVG_6_TO_11_OBSERVED_MONTHS_NO_TREND'

        WHEN l12.latest_12_observed_months > 0
        THEN 'LATEST_PRICE_LT_12_OBSERVED_MONTHS_NO_TREND'

        ELSE 'NO_HISTORY_AVAILABLE'
    END                                                 AS forecast_start_price_source,

    -- sparse confidence flag
    CASE
        WHEN l12.latest_12_observed_months >= 6  THEN 'PRICE_6MO_AVG'
        WHEN l12.latest_12_observed_months >= 3  THEN 'PRICE_3_TO_5_MO_AVG'
        WHEN l12.latest_12_observed_months >= 1  THEN 'PRICE_LAST_OBSERVED'
        ELSE                                          'NO_PRICE_AVAILABLE'
    END                                                 AS sparse_price_confidence,

    CASE
        WHEN l12.latest_12_observed_months < 6   THEN 1
        ELSE                                          0
    END                                                 AS is_sparse_price_flag

FROM calendar_window_agg cwa
LEFT JOIN latest_12_observed_agg l12
  ON cwa.run_id              = l12.run_id
 AND cwa.HYBRID_MODEL_KEY_3T = l12.HYBRID_MODEL_KEY_3T
 AND cwa.mtrl_num             = l12.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v10 la
  ON cwa.run_id              = la.run_id
 AND cwa.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND cwa.mtrl_num             = la.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 6: RUN-RESOLVED ASSUMPTIONS
   - Anchor = latest raw actual before jump-off
   - Trend = 0 for all series (v10 design)
   - Price comes from material assumptions step only
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v10 AS
SELECT
    e.run_id,
    e.jump_off_month,
    e.history_start_dt,
    e.history_end_dt,

    e.HYBRID_MODEL_KEY_3T,
    e.mtrl_num,

    -- tier metadata
    e.MODEL_TIER,
    e.sap_months,
    e.l2_months,

    -- backward-compatible descriptor
    e.customer_group_key_id,
    e.customer_group_key_desc,

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

    e.first_month,
    la.anchor_month,
    CAST(months_between(e.jump_off_month, e.first_month) AS INT) AS months_since_first_asof_jumpoff,

    la.anchor_contract_price,
    la.anchor_wac_weighted,
    la.anchor_wac_spread,
    la.anchor_total_sls_qty,
    la.anchor_total_net_cos,

    -- resolved forecast start price from material assumptions
    ma.forecast_start_contract_price,
    ma.forecast_start_wac_spread,
    ma.forecast_start_price_source,
    ma.sparse_price_confidence,
    ma.is_sparse_price_flag,

    -- diagnostic history stats
    ma.recent_12m_months,
    ma.prior_12m_months,
    ma.latest_12_observed_months,

    -- trend = 0 for all (v10 design)
    0                                                   AS resolved_monthly_trend_pct,
    'STATIC_NO_TREND'                                   AS trend_source

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v10 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v10 la
  ON e.run_id              = la.run_id
 AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = la.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v10 ma
  ON e.run_id              = ma.run_id
 AND e.HYBRID_MODEL_KEY_3T = ma.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = ma.mtrl_num
WHERE
    e.is_eligible_for_run = 1
    AND la.anchor_contract_price IS NOT NULL
;


/* ---------------------------------------------------------------------
   STEP 7: FUTURE ACTUAL MONTHS FOR BACKTEST
   - Uses actual observed months after jump-off
   - Limited to 60 months forward
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v10 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.HYBRID_MODEL_KEY_3T,
    ra.mtrl_num,
    b.cal_month_start_dt                                AS forecast_month,
    CAST(months_between(b.cal_month_start_dt, ra.jump_off_month) AS INT) + 1
                                                        AS forecast_horizon_month_num,
    DATE_FORMAT(b.cal_month_start_dt, 'yyyy-MM')        AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v10 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10 b
  ON ra.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = b.mtrl_num
 AND b.cal_month_start_dt >= ra.jump_off_month
 AND b.cal_month_start_dt <  ADD_MONTHS(ra.jump_off_month, 60)
;


/* ---------------------------------------------------------------------
   STEP 8: FORECASTED CONTRACT PRICE
   - Forecast from forecast_start_contract_price using 0 trend
   - forecast_start_contract_price replaces anchor_contract_price
     as the starting point; trend compounds from there
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v10 AS
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

    ra.customer_group_key_id,
    ra.customer_group_key_desc,

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

    ra.recent_12m_months,
    ra.prior_12m_months,
    ra.latest_12_observed_months,

    ra.resolved_monthly_trend_pct,
    ra.trend_source,

    fam.forecast_month,
    fam.forecast_horizon_month_num,
    fam.forecast_year_month,

    -- forecast compounds from forecast_start_contract_price with 0 trend
    -- GREATEST guards against negative values from floating point
    CASE
        WHEN ra.forecast_start_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ra.forecast_start_contract_price * POWER(
                1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                fam.forecast_horizon_month_num
            ),
            0
        )
    END                                                 AS forecasted_contract_price

FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v10 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v10 fam
  ON ra.run_id              = fam.run_id
 AND ra.HYBRID_MODEL_KEY_3T = fam.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = fam.mtrl_num
;


-- /* ---------------------------------------------------------------------
--    STEP 9: EVALUATION DETAIL
--    - Compares forecast vs actual contract price
--    - Uses actual qty to compute dollar error
--    --------------------------------------------------------------------- */
-- CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v10 AS
-- WITH joined AS (
--     SELECT
--         f.run_id,
--         f.jump_off_month,
--         f.HYBRID_MODEL_KEY_3T,
--         f.mtrl_num,
--         f.forecast_month,
--         f.forecast_horizon_month_num,
--         f.forecast_year_month,

--         f.MODEL_TIER,
--         f.sap_months,
--         f.l2_months,
--         f.sparse_price_confidence,
--         f.is_sparse_price_flag,

--         f.customer_group_key_id,
--         f.customer_group_key_desc,

--         f.cust_segment,
--         f.acct_classification,
--         f.cust_prod_category,

--         f.national_grp_id,
--         f.national_grp_desc,

--         f.mtrl_nme_nvgton,
--         f.ndc_num,
--         f.product_family,
--         f.therapeutic_class,
--         f.manufacturer_id,
--         f.manufacturer_name,
--         f.final_product_group,
--         f.final_product_group_level,

--         f.first_month,
--         f.anchor_month,
--         f.months_since_first_asof_jumpoff,

--         f.anchor_contract_price,
--         f.anchor_wac_weighted,
--         f.anchor_wac_spread,

--         f.forecast_start_contract_price,
--         f.forecast_start_price_source,

--         f.resolved_monthly_trend_pct,
--         f.trend_source,
--         f.forecasted_contract_price,

--         f.recent_12m_months,
--         f.prior_12m_months,
--         f.latest_12_observed_months,

--         a.contract_price        AS actual_contract_price,
--         a.account_class_cd      AS account_class_cd,
--         a.wac_weighted          AS actual_wac_weighted,
--         a.wac_spread            AS actual_wac_spread,
--         a.total_sls_qty         AS actual_sls_qty,
--         a.total_net_cos         AS actual_net_cos
--     FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v10 f
--     LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10 a
--       ON f.HYBRID_MODEL_KEY_3T = a.HYBRID_MODEL_KEY_3T
--      AND f.mtrl_num             = a.mtrl_num
--      AND f.forecast_month       = a.cal_month_start_dt
-- ),
-- calc AS (
--     SELECT
--         j.*,

--         -- dollars using actual qty to isolate price forecast error
--         j.forecasted_contract_price * j.actual_sls_qty  AS forecasted_dollars,
--         j.actual_contract_price * j.actual_sls_qty      AS actual_dollars,

--         -- price error
--         (j.forecasted_contract_price - j.actual_contract_price)
--                                                         AS error_contract_price,
--         ABS(j.forecasted_contract_price - j.actual_contract_price)
--                                                         AS ae_contract_price,

--         CASE
--             WHEN j.actual_contract_price IS NOT NULL
--              AND j.actual_contract_price <> 0
--             THEN (j.forecasted_contract_price - j.actual_contract_price)
--                  / j.actual_contract_price
--         END                                             AS bias_contract_price,

--         CASE
--             WHEN j.actual_contract_price IS NOT NULL
--              AND j.actual_contract_price <> 0
--             THEN ABS(j.forecasted_contract_price - j.actual_contract_price)
--                  / ABS(j.actual_contract_price)
--         END                                             AS ape_contract_price,

--         -- dollar error
--         (j.forecasted_contract_price * j.actual_sls_qty)
--             - (j.actual_contract_price * j.actual_sls_qty)
--                                                         AS error_dollars,
--         ABS(
--             (j.forecasted_contract_price * j.actual_sls_qty)
--             - (j.actual_contract_price * j.actual_sls_qty)
--         )                                               AS ae_dollars,

--         CASE
--             WHEN (j.actual_contract_price * j.actual_sls_qty) IS NOT NULL
--              AND (j.actual_contract_price * j.actual_sls_qty) <> 0
--             THEN (
--                 (j.forecasted_contract_price * j.actual_sls_qty)
--                 - (j.actual_contract_price * j.actual_sls_qty)
--             ) / (j.actual_contract_price * j.actual_sls_qty)
--         END                                             AS bias_dollars,

--         CASE
--             WHEN (j.actual_contract_price * j.actual_sls_qty) IS NOT NULL
--              AND (j.actual_contract_price * j.actual_sls_qty) <> 0
--             THEN ABS(
--                 (j.forecasted_contract_price * j.actual_sls_qty)
--                 - (j.actual_contract_price * j.actual_sls_qty)
--             ) / ABS(j.actual_contract_price * j.actual_sls_qty)
--         END                                             AS ape_dollars,

--         -- implied spread from forecast using actual WAC
--         CASE
--             WHEN j.actual_wac_weighted IS NOT NULL
--              AND j.actual_wac_weighted <> 0
--             THEN (j.forecasted_contract_price / j.actual_wac_weighted) - 1
--         END                                             AS implied_forecast_wac_spread

--     FROM joined j
-- ),
-- weighted AS (
--     SELECT
--         c.*,

--         CASE
--             WHEN SUM(ABS(c.error_dollars)) OVER (PARTITION BY c.run_id) <> 0
--             THEN ABS(c.error_dollars)
--                  / SUM(ABS(c.error_dollars)) OVER (PARTITION BY c.run_id)
--         END                                             AS weighted_percent_error,

--         CASE
--             WHEN SUM(ABS(c.actual_dollars)) OVER (PARTITION BY c.run_id) <> 0
--             THEN ABS(c.actual_dollars)
--                  / SUM(ABS(c.actual_dollars)) OVER (PARTITION BY c.run_id)
--         END                                             AS revenue_share

--     FROM calc c
-- ),
-- ranked AS (
--     SELECT
--         w.*,
--         NTILE(5) OVER (
--             PARTITION BY w.run_id
--             ORDER BY ABS(w.actual_dollars) DESC NULLS LAST
--         ) AS revenue_quintile_desc
--     FROM weighted w
-- )
-- SELECT
--     r.*,

--     CASE
--         WHEN r.revenue_quintile_desc = 1         THEN 'TOP_20'
--         WHEN r.revenue_quintile_desc IN (2,3,4)  THEN 'MIDDLE_60'
--         WHEN r.revenue_quintile_desc = 5         THEN 'BOTTOM_20'
--         ELSE 'UNKNOWN'
--     END                                                 AS materiality_band,

--     CASE
--         WHEN r.revenue_quintile_desc = 1         THEN 0.03
--         WHEN r.revenue_quintile_desc IN (2,3,4)  THEN 0.10
--         WHEN r.revenue_quintile_desc = 5         THEN 0.20
--         ELSE NULL
--     END                                                 AS materiality_threshold_pct,

--     CASE
--         WHEN r.ape_contract_price IS NOT NULL
--          AND r.ape_contract_price < 0.20 THEN 1
--         WHEN r.ape_contract_price IS NOT NULL    THEN 0
--         ELSE NULL
--     END                                                 AS pass_flag_vs_actual_error_threshold,

--     CASE
--         WHEN r.ape_dollars IS NOT NULL
--          AND (
--                 (r.revenue_quintile_desc = 1        AND r.ape_dollars <= 0.03) OR
--                 (r.revenue_quintile_desc IN (2,3,4) AND r.ape_dollars <= 0.10) OR
--                 (r.revenue_quintile_desc = 5        AND r.ape_dollars <= 0.20)
--              )
--         THEN 1
--         WHEN r.ape_dollars IS NOT NULL           THEN 0
--         ELSE NULL
--     END                                                 AS pass_flag_vs_materiality_threshold,

--     CASE
--         WHEN r.ape_dollars IS NOT NULL
--          AND (
--                 (r.revenue_quintile_desc = 1        AND r.ape_dollars > 0.03) OR
--                 (r.revenue_quintile_desc IN (2,3,4) AND r.ape_dollars > 0.10) OR
--                 (r.revenue_quintile_desc = 5        AND r.ape_dollars > 0.20)
--              )
--          AND ABS(r.actual_dollars) IS NOT NULL
--          AND ABS(r.actual_dollars) > 0
--         THEN 'CRITICAL'
--         WHEN r.ape_contract_price IS NOT NULL
--          AND r.ape_contract_price > 0.20         THEN 'MODERATE'
--         ELSE 'PASS'
--     END                                                 AS review_priority,

--     CASE
--         WHEN r.forecasted_contract_price > 3 * r.anchor_contract_price THEN 1
--         ELSE 0
--     END                                                 AS forecast_explosion_flag

-- FROM ranked r
-- WHERE forecast_month IS NOT NULL
-- ;


CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v10 AS

-- =====================================================================
-- OPTIMIZATION NOTES
-- 1. run_totals: pre-aggregate SUM(abs_error_dollars) and
--    SUM(abs_actual_dollars) per run_id in a tiny CTE (~3 rows).
--    Replaces two SUM(...) OVER (PARTITION BY run_id) window passes
--    on the full detail table.
-- 2. series_dollars: aggregate total actual dollars per
--    run_id + series to drive NTILE ranking. Computed once on a
--    small grain, then joined back. Replaces NTILE on the full
--    row-level dataset.
-- 3. actual data pre-filtered: base table filtered to only
--    forecast months before joining, reducing join input size.
-- =====================================================================

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

        -- f.customer_group_key_id,
        -- f.customer_group_key_desc,

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

        f.recent_12m_months,
        f.prior_12m_months,
        f.latest_12_observed_months,

        a.contract_price    AS actual_contract_price,
        a.account_class_cd  AS account_class_cd,
        a.wac_weighted      AS actual_wac_weighted,
        a.wac_spread        AS actual_wac_spread,
        a.total_sls_qty     AS actual_sls_qty,
        a.total_net_cos     AS actual_net_cos

    FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v10 f
    -- Pre-filter actuals to only months that appear in the forecast table
    -- before joining, avoiding a full base table scan per row
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
        total_net_cos
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10
    WHERE exclude_from_training_flag = 0          -- exclude bad-data actuals
) a
  ON f.HYBRID_MODEL_KEY_3T = a.HYBRID_MODEL_KEY_3T
 AND f.mtrl_num             = a.mtrl_num
 AND f.forecast_month       = a.cal_month_start_dt
WHERE f.forecast_month IS NOT NULL
),

-- Compute all error metrics at row level
calc AS (
    SELECT
        j.*,

        -- pre-compute dollar columns once; reused in multiple error expressions
        j.forecasted_contract_price * j.actual_sls_qty          AS forecasted_dollars,
        j.actual_contract_price     * j.actual_sls_qty          AS actual_dollars,

        -- price error
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

        -- dollar error — expressed in terms of pre-computed dollar cols below
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

-- =====================================================================
-- OPT 1: Pre-aggregate run-level totals — replaces two
-- SUM(...) OVER (PARTITION BY run_id) window scans on the full table.
-- Result is ~3 rows (one per run), joined back as a scalar.
-- =====================================================================
run_totals AS (
    SELECT
        run_id,
        SUM(ABS(error_dollars))     AS total_abs_error_dollars,
        SUM(ABS(actual_dollars))    AS total_abs_actual_dollars
    FROM calc
    GROUP BY run_id
),

-- =====================================================================
-- OPT 2: Pre-aggregate series-level total actual dollars per run.
-- NTILE ranking is applied here on a small series-grain table
-- (~series_cnt * run_cnt rows) rather than on the full row-level table.
-- =====================================================================
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
)

-- Final SELECT: joins pre-computed aggregates back to row-level calc
SELECT
    c.*,

    -- weighted error / revenue share via pre-aggregated run totals
    CASE
        WHEN rt.total_abs_error_dollars <> 0
        THEN ABS(c.error_dollars) / rt.total_abs_error_dollars
    END                                                         AS weighted_percent_error,

    CASE
        WHEN rt.total_abs_actual_dollars <> 0
        THEN ABS(c.actual_dollars) / rt.total_abs_actual_dollars
    END                                                         AS revenue_share,

    -- quintile and materiality from series-grain rank
    sr.revenue_quintile_desc,

    CASE
        WHEN sr.revenue_quintile_desc = 1        THEN 'TOP_20'
        WHEN sr.revenue_quintile_desc IN (2,3,4) THEN 'MIDDLE_60'
        WHEN sr.revenue_quintile_desc = 5        THEN 'BOTTOM_20'
        ELSE 'UNKNOWN'
    END                                                         AS materiality_band,

    CASE
        WHEN sr.revenue_quintile_desc = 1        THEN 0.03
        WHEN sr.revenue_quintile_desc IN (2,3,4) THEN 0.10
        WHEN sr.revenue_quintile_desc = 5        THEN 0.20
        ELSE NULL
    END                                                         AS materiality_threshold_pct,

    -- pass/fail flags
    CASE
        WHEN c.ape_contract_price IS NOT NULL
         AND c.ape_contract_price < 0.20 THEN 1
        WHEN c.ape_contract_price IS NOT NULL    THEN 0
        ELSE NULL
    END                                                         AS pass_flag_vs_actual_error_threshold,

    CASE
        WHEN c.ape_dollars IS NOT NULL
         AND (
                (sr.revenue_quintile_desc = 1        AND c.ape_dollars <= 0.03) OR
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
JOIN run_totals  rt ON c.run_id              = rt.run_id
JOIN series_ranked sr
  ON c.run_id              = sr.run_id
 AND c.HYBRID_MODEL_KEY_3T = sr.HYBRID_MODEL_KEY_3T
 AND c.mtrl_num             = sr.mtrl_num
;

/* ---------------------------------------------------------------------
   STEP 10: EVAL SUMMARY BY RUN
   - Adds breakdowns by MODEL_TIER and sparse_price_confidence
     so you can see where v10 granularity changes move the needle
   --------------------------------------------------------------------- */

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_run_v10 AS
SELECT
    run_id,
    MODEL_TIER,
    sparse_price_confidence,

    COUNT(*)                                            AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', HYBRID_MODEL_KEY_3T, mtrl_num))
                                                        AS series_cnt,

    AVG(ape_contract_price)                             AS mape_contract_price,
    AVG(ape_dollars)                                    AS mape_dollars,

    SUM(ae_contract_price)
        / NULLIF(SUM(ABS(actual_contract_price)), 0)    AS wape_contract_price,
    SUM(ae_dollars)
        / NULLIF(SUM(ABS(actual_dollars)), 0)           AS wape_dollars,

    AVG(bias_contract_price)                            AS avg_bias_contract_price,
    AVG(bias_dollars)                                   AS avg_bias_dollars,

    COUNT_IF(pass_flag_vs_actual_error_threshold = 1)   AS pass_cnt_price,
    COUNT_IF(pass_flag_vs_actual_error_threshold = 0)   AS fail_cnt_price,

    COUNT_IF(pass_flag_vs_materiality_threshold = 1)    AS pass_cnt_materiality,
    COUNT_IF(pass_flag_vs_materiality_threshold = 0)    AS fail_cnt_materiality,

    COUNT_IF(forecast_explosion_flag = 1)               AS explosion_row_cnt

FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v10
GROUP BY
    run_id,
    MODEL_TIER,
    sparse_price_confidence
ORDER BY
    run_id,
    MODEL_TIER,
    sparse_price_confidence
;