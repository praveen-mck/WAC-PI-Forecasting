/* =====================================================================
   CONTRACT PRICE BACKTEST PIPELINE (v16)
   ---------------------------------------------------------------------
   DESIGN GOALS
   - Rolling-origin backtesting
   - Monthly forecast frequency
   - 5-year forward horizon (60 months)
   - 1:1 unique evaluation grain:
       run_id + HYBRID_MODEL_KEY_3T + mtrl_num + forecast_month
   - Simple / explainable v16 baseline
   - Three-tier granularity: SAP_CUST -> L2 -> NATIONAL_GRP_FALLBACK
   - Trend = 0 for all series; price anchor uses prior/observed avg logic
   - Uses actual qty for dollar-error evaluation
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: BACKTEST RUNS
   - Same jump-off points as WAC pipeline
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_runs_v16 AS
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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v16 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16
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
        -- MAX(customer_group_key_id)      AS customer_group_key_id,
        -- MAX(customer_group_key_desc)    AS customer_group_key_desc,

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
        MAX(WAC)                        AS WAC,
        MAX(TOTAL_NET_REVENUE)          AS Total_Net_Revenue,

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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v16 AS
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
    -- sp.customer_group_key_id,
    -- sp.customer_group_key_desc,

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

FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v16 r
CROSS JOIN uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v16 sp
;


/* ---------------------------------------------------------------------
   STEP 3: RUN-SPECIFIC LAST ACTUAL (RAW)
   - Anchor comes from raw base table, not training-clean
   - Uses latest observed month <= history_end_dt
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v16 AS
WITH eligible AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v16
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
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16 b
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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v16 AS
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

    -- e.customer_group_key_id,
    -- e.customer_group_key_desc,

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

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v16 e
JOIN uspd_analytics_den.analytics_gold.contract_price_training_clean_v16 t
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
   - Aligns with v16 price logic: no trend, price fallback hierarchy
   - Prior 12m avg (>=6 months) -> latest 12 observed avg (>=6) -> anchor
   - Trend = 0 for all series
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v16 AS
WITH last_hist_month AS (
    SELECT
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(cal_month_start_dt) AS anchor_month
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v16
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
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v16 h
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
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v16 h
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
    -- Trend = 0 for all series (v16 design)
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
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v16 la
  ON cwa.run_id              = la.run_id
 AND cwa.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND cwa.mtrl_num             = la.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 6: RUN-RESOLVED ASSUMPTIONS
   - Anchor = latest raw actual before jump-off
   - Trend = 0 for all series (v16 design)
   - Price comes from material assumptions step only
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v16 AS
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
    -- e.customer_group_key_id,
    -- e.customer_group_key_desc,

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

    -- trend = 0 for all (v16 design)
    0                                                   AS resolved_monthly_trend_pct,
    'STATIC_NO_TREND'                                   AS trend_source

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v16 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v16 la
  ON e.run_id              = la.run_id
 AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = la.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v16 ma
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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v16 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.HYBRID_MODEL_KEY_3T,
    ra.mtrl_num,
    b.cal_month_start_dt                                AS forecast_month,
    CAST(months_between(b.cal_month_start_dt, ra.jump_off_month) AS INT) + 1
                                                        AS forecast_horizon_month_num,
    DATE_FORMAT(b.cal_month_start_dt, 'yyyy-MM')        AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v16 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16 b
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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v16 AS
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

    -- ra.customer_group_key_id,
    -- ra.customer_group_key_desc,

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

FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v16 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v16 fam
  ON ra.run_id              = fam.run_id
 AND ra.HYBRID_MODEL_KEY_3T = fam.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = fam.mtrl_num
LEFT JOIN (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(WAC) AS WAC,
        MAX(TOTAL_NET_REVENUE) AS total_net_revenue
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16
    GROUP BY
        HYBRID_MODEL_KEY_3T,
        mtrl_num
) src
  ON ra.HYBRID_MODEL_KEY_3T = src.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = src.mtrl_num
;




/* =====================================================================
   CONTRACT PRICE BACKTEST PIPELINE (v16)
   ---------------------------------------------------------------------
   DESIGN GOALS
   - Rolling-origin backtesting
   - Monthly forecast frequency
   - 5-year forward horizon (60 months)
   - 1:1 unique evaluation grain:
       run_id + HYBRID_MODEL_KEY_3T + mtrl_num + forecast_month
   - Simple / explainable v16 baseline
   - Three-tier granularity: SAP_CUST -> L2 -> NATIONAL_GRP_FALLBACK
   - Trend = 0 for all series; price anchor uses prior/observed avg logic
   - Uses actual qty for dollar-error evaluation
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: BACKTEST RUNS
   - Same jump-off points as WAC pipeline
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_runs_v16 AS
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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v16 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16
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
        -- MAX(customer_group_key_id)      AS customer_group_key_id,
        -- MAX(customer_group_key_desc)    AS customer_group_key_desc,

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
        MAX(WAC)                        AS WAC,
        MAX(TOTAL_NET_REVENUE)          AS Total_Net_Revenue,

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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v16 AS
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
    -- sp.customer_group_key_id,
    -- sp.customer_group_key_desc,

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

FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v16 r
CROSS JOIN uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v16 sp
;


/* ---------------------------------------------------------------------
   STEP 3: RUN-SPECIFIC LAST ACTUAL (RAW)
   - Anchor comes from raw base table, not training-clean
   - Uses latest observed month <= history_end_dt
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v16 AS
WITH eligible AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v16
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
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16 b
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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v16 AS
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

    -- e.customer_group_key_id,
    -- e.customer_group_key_desc,

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

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v16 e
JOIN uspd_analytics_den.analytics_gold.contract_price_training_clean_v16 t
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
   - Aligns with v16 price logic: no trend, price fallback hierarchy
   - Prior 12m avg (>=6 months) -> latest 12 observed avg (>=6) -> anchor
   - Trend = 0 for all series
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v16 AS
WITH last_hist_month AS (
    SELECT
        run_id,
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(cal_month_start_dt) AS anchor_month
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v16
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
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v16 h
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
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v16 h
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
    -- Trend = 0 for all series (v16 design)
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
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v16 la
  ON cwa.run_id              = la.run_id
 AND cwa.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND cwa.mtrl_num             = la.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 6: RUN-RESOLVED ASSUMPTIONS
   - Anchor = latest raw actual before jump-off
   - Trend = 0 for all series (v16 design)
   - Price comes from material assumptions step only
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v16 AS
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
    -- e.customer_group_key_id,
    -- e.customer_group_key_desc,

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

    -- trend = 0 for all (v16 design)
    0                                                   AS resolved_monthly_trend_pct,
    'STATIC_NO_TREND'                                   AS trend_source

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v16 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v16 la
  ON e.run_id              = la.run_id
 AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = la.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v16 ma
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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v16 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.HYBRID_MODEL_KEY_3T,
    ra.mtrl_num,
    b.cal_month_start_dt                                AS forecast_month,
    CAST(months_between(b.cal_month_start_dt, ra.jump_off_month) AS INT) + 1
                                                        AS forecast_horizon_month_num,
    DATE_FORMAT(b.cal_month_start_dt, 'yyyy-MM')        AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v16 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16 b
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
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v16 AS
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

    -- ra.customer_group_key_id,
    -- ra.customer_group_key_desc,

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

FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v16 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v16 fam
  ON ra.run_id              = fam.run_id
 AND ra.HYBRID_MODEL_KEY_3T = fam.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = fam.mtrl_num
LEFT JOIN (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(WAC) AS WAC,
        MAX(TOTAL_NET_REVENUE) AS total_net_revenue
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v16
    GROUP BY
        HYBRID_MODEL_KEY_3T,
        mtrl_num
) src
  ON ra.HYBRID_MODEL_KEY_3T = src.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = src.mtrl_num
;




