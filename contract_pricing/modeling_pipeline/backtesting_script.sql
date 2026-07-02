/* =====================================================================
   CONTRACT PRICE BACKTEST PIPELINE (v5)
   ---------------------------------------------------------------------
   DESIGN GOALS
   - Rolling-origin backtesting
   - Monthly forecast frequency
   - 5-year forward horizon (60 months)
   - 1:1 unique evaluation grain:
       run_id + customer_group_key_id + mtrl_num + forecast_month
   - Simple / explainable v5 baseline
   - Material-level forecast with hierarchical fallbacks
   - Uses actual qty for dollar-error evaluation
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: BACKTEST RUNS
   - Same jump-off points as WAC pipeline
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_runs_v5 AS
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
   - One row per customer + material series
   - Used for run eligibility and diagnostics
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v5 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v5
),
ranked AS (
    SELECT
        b.*,
        ROW_NUMBER() OVER (
            PARTITION BY b.customer_group_key_id, b.mtrl_num
            ORDER BY b.cal_month_start_dt ASC
        ) AS rn_first,
        ROW_NUMBER() OVER (
            PARTITION BY b.customer_group_key_id, b.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn_last
    FROM base b
),
first_row AS (
    SELECT
        customer_group_key_id,
        mtrl_num,
        cal_month_start_dt AS first_month,
        contract_price AS first_contract_price
    FROM ranked
    WHERE rn_first = 1
),
last_row AS (
    SELECT
        customer_group_key_id,
        mtrl_num,
        cal_month_start_dt AS last_actual_month,
        contract_price AS last_actual_contract_price,
        wac_weighted AS last_actual_wac_weighted,
        wac_spread AS last_actual_wac_spread
    FROM ranked
    WHERE rn_last = 1
),
agg AS (
    SELECT
        customer_group_key_id,
        mtrl_num,

        MAX(cust_segment) AS cust_segment,
        MAX(acct_classification) AS acct_classification,
        MAX(cust_prod_category) AS cust_prod_category,

        MAX(national_grp_id) AS national_grp_id,
        MAX(national_grp_desc) AS national_grp_desc,
        MAX(customer_group_key_desc) AS customer_group_key_desc,

        MAX(mtrl_nme_nvgton) AS mtrl_nme_nvgton,
        MAX(ndc_num) AS ndc_num,

        MAX(product_family) AS product_family,
        MAX(therapeutic_class) AS therapeutic_class,
        MAX(manufacturer_id) AS manufacturer_id,
        MAX(manufacturer_name) AS manufacturer_name,
        MAX(final_product_group) AS final_product_group,
        MAX(final_product_group_level) AS final_product_group_level,

        COUNT(DISTINCT cal_month_start_dt) AS total_months_all_time
    FROM base
    GROUP BY
        customer_group_key_id,
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
  ON a.customer_group_key_id = f.customer_group_key_id
 AND a.mtrl_num = f.mtrl_num
LEFT JOIN last_row l
  ON a.customer_group_key_id = l.customer_group_key_id
 AND a.mtrl_num = l.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 2: RUN ELIGIBILITY
   - Eligible if series existed on or before run history_end_dt
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v5 AS
SELECT
    r.run_id,
    r.jump_off_month,
    r.lookback_years,
    r.history_start_dt,
    r.history_end_dt,

    sp.customer_group_key_id,
    sp.mtrl_num,

    sp.cust_segment,
    sp.acct_classification,
    sp.cust_prod_category,

    sp.national_grp_id,
    sp.national_grp_desc,
    sp.customer_group_key_desc,

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
        WHEN sp.first_month IS NULL THEN 'NO_HISTORY'
        WHEN sp.first_month > r.history_end_dt THEN 'NOT_LAUNCHED_YET'
        ELSE 'ELIGIBLE'
    END AS data_coverage_flag

FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v5 r
CROSS JOIN uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v5 sp
;


/* ---------------------------------------------------------------------
   STEP 3: RUN-SPECIFIC LAST ACTUAL (RAW)
   - Anchor comes from raw base table, not training-clean
   - Uses latest observed month <= history_end_dt
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v5 AS
WITH eligible AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v5
    WHERE is_eligible_for_run = 1
),
raw_hist AS (
    SELECT
        e.run_id,
        e.jump_off_month,
        e.history_end_dt,

        b.customer_group_key_id,
        b.mtrl_num,
        b.cal_month_start_dt,
        b.contract_price,
        b.wac_weighted,
        b.wac_spread,
        b.total_sls_qty,
        b.total_net_cos,

        ROW_NUMBER() OVER (
            PARTITION BY e.run_id, b.customer_group_key_id, b.mtrl_num
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v5 b
      ON e.customer_group_key_id = b.customer_group_key_id
     AND e.mtrl_num = b.mtrl_num
     AND b.cal_month_start_dt <= e.history_end_dt
)
SELECT
    run_id,
    jump_off_month,
    history_end_dt,
    customer_group_key_id,
    mtrl_num,
    cal_month_start_dt AS anchor_month,
    contract_price AS anchor_contract_price,
    wac_weighted AS anchor_wac_weighted,
    wac_spread AS anchor_wac_spread,
    total_sls_qty AS anchor_total_sls_qty,
    total_net_cos AS anchor_total_net_cos
FROM raw_hist
WHERE rn = 1
;


/* ---------------------------------------------------------------------
   STEP 4: RUN-SPECIFIC CLEAN HIST PANEL
   - Historical panel used for model fitting only
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v5 AS
SELECT
    e.run_id,
    e.jump_off_month,
    e.lookback_years,
    e.history_start_dt,
    e.history_end_dt,

    e.customer_group_key_id,
    e.mtrl_num,

    e.cust_segment,
    e.acct_classification,
    e.cust_prod_category,

    e.national_grp_id,
    e.national_grp_desc,
    e.customer_group_key_desc,

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
    t.contract_price_change_outlier_flag
FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v5 e
JOIN uspd_analytics_den.analytics_gold.contract_price_training_clean_v5 t
  ON e.customer_group_key_id = t.customer_group_key_id
 AND e.mtrl_num = t.mtrl_num
 AND t.cal_month_start_dt >= e.history_start_dt
 AND t.cal_month_start_dt <= e.history_end_dt
WHERE
    e.is_eligible_for_run = 1
    AND t.include_for_modeling_flag = 1
;


/* ---------------------------------------------------------------------
   STEP 5A: RUN MATERIAL-LEVEL ASSUMPTIONS
   - Recent 12m vs previous 12m average contract price
   - Conservative monthly trend cap: [-2%, +2%]
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v5 AS
WITH last_hist_month AS (
    SELECT
        run_id,
        customer_group_key_id,
        mtrl_num,
        MAX(cal_month_start_dt) AS anchor_month
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v5
    GROUP BY
        run_id,
        customer_group_key_id,
        mtrl_num
),
agg AS (
    SELECT
        lhm.run_id,
        lhm.customer_group_key_id,
        lhm.mtrl_num,
        lhm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.cal_month_start_dt
        END) AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -24)
             AND h.cal_month_start_dt <= ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.cal_month_start_dt
        END) AS prior_12m_months,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.contract_price
        END) AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN h.cal_month_start_dt > ADD_MONTHS(lhm.anchor_month, -24)
             AND h.cal_month_start_dt <= ADD_MONTHS(lhm.anchor_month, -12)
            THEN h.contract_price
        END) AS prior_12m_avg_contract_price
    FROM last_hist_month lhm
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v5 h
      ON lhm.run_id = h.run_id
     AND lhm.customer_group_key_id = h.customer_group_key_id
     AND lhm.mtrl_num = h.mtrl_num
    GROUP BY
        lhm.run_id,
        lhm.customer_group_key_id,
        lhm.mtrl_num,
        lhm.anchor_month
)
SELECT
    a.*,

    CASE
        WHEN a.recent_12m_months >= 6
         AND a.prior_12m_months >= 6
         AND a.prior_12m_avg_contract_price IS NOT NULL
         AND a.prior_12m_avg_contract_price > 0
        THEN POWER(
                a.recent_12m_avg_contract_price / a.prior_12m_avg_contract_price,
                1.0 / 12.0
             ) - 1
        ELSE 0
    END AS monthly_trend_pct_raw,

    CASE
        WHEN a.recent_12m_months >= 6
         AND a.prior_12m_months >= 6
         AND a.prior_12m_avg_contract_price IS NOT NULL
         AND a.prior_12m_avg_contract_price > 0
        THEN LEAST(
                GREATEST(
                    POWER(
                        a.recent_12m_avg_contract_price / a.prior_12m_avg_contract_price,
                        1.0 / 12.0
                    ) - 1,
                    -0.02
                ),
                0.02
             )
        ELSE 0
    END AS expected_monthly_trend_pct,

    CASE
        WHEN a.recent_12m_months >= 6 AND a.prior_12m_months >= 6
        THEN 'MATERIAL_24M_TREND'
        WHEN a.recent_12m_months >= 6
        THEN 'MATERIAL_RECENT_ONLY'
        ELSE 'MATERIAL_NO_SIGNAL'
    END AS material_trend_source

FROM agg a
;


/* ---------------------------------------------------------------------
   STEP 5B: RUN CUSTOMER + PRODUCT GROUP FALLBACK
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_fallback_product_group_v5 AS
WITH monthly_group AS (
    SELECT
        run_id,
        customer_group_key_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        final_product_group,
        final_product_group_level,
        cal_month_start_dt,

        SUM(total_net_cos) AS total_net_cos,
        SUM(total_sls_qty) AS total_sls_qty,
        SUM(total_net_cos) / NULLIF(SUM(total_sls_qty), 0) AS contract_price,
        SUM(wac_weighted * total_sls_qty) / NULLIF(SUM(total_sls_qty), 0) AS wac_weighted,
        (SUM(total_net_cos) / NULLIF(SUM(wac_weighted * total_sls_qty), 0)) - 1 AS wac_spread
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v5
    WHERE final_product_group IS NOT NULL
      AND TRIM(final_product_group) <> ''
      AND final_product_group <> 'UNKNOWN'
    GROUP BY
        run_id,
        customer_group_key_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        final_product_group,
        final_product_group_level,
        cal_month_start_dt
),
last_month AS (
    SELECT
        run_id,
        customer_group_key_id,
        final_product_group,
        MAX(cal_month_start_dt) AS anchor_month
    FROM monthly_group
    GROUP BY
        run_id,
        customer_group_key_id,
        final_product_group
),
agg AS (
    SELECT
        lm.run_id,
        lm.customer_group_key_id,
        lm.final_product_group,
        lm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN mg.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN mg.cal_month_start_dt
        END) AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN mg.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND mg.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN mg.cal_month_start_dt
        END) AS prior_12m_months,

        AVG(CASE
            WHEN mg.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN mg.contract_price
        END) AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN mg.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND mg.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN mg.contract_price
        END) AS prior_12m_avg_contract_price
    FROM last_month lm
    LEFT JOIN monthly_group mg
      ON lm.run_id = mg.run_id
     AND lm.customer_group_key_id = mg.customer_group_key_id
     AND lm.final_product_group = mg.final_product_group
    GROUP BY
        lm.run_id,
        lm.customer_group_key_id,
        lm.final_product_group,
        lm.anchor_month
)
SELECT
    a.run_id,
    a.customer_group_key_id,
    a.final_product_group,
    a.anchor_month,

    CASE
        WHEN a.recent_12m_months >= 6
         AND a.prior_12m_months >= 6
         AND a.prior_12m_avg_contract_price IS NOT NULL
         AND a.prior_12m_avg_contract_price > 0
        THEN LEAST(
                GREATEST(
                    POWER(
                        a.recent_12m_avg_contract_price / a.prior_12m_avg_contract_price,
                        1.0 / 12.0
                    ) - 1,
                    -0.02
                ),
                0.02
             )
        ELSE 0
    END AS expected_monthly_trend_pct,

    CASE
        WHEN a.recent_12m_months >= 6 AND a.prior_12m_months >= 6
        THEN 'CUSTOMER_PRODUCT_GROUP_24M_TREND'
        WHEN a.recent_12m_months >= 6
        THEN 'CUSTOMER_PRODUCT_GROUP_RECENT_ONLY'
        ELSE 'CUSTOMER_PRODUCT_GROUP_NO_SIGNAL'
    END AS fallback_source
FROM agg a
;


/* ---------------------------------------------------------------------
   STEP 5C: RUN CUSTOMER + CATEGORY FALLBACK
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_fallback_category_v5 AS
WITH monthly_cat AS (
    SELECT
        run_id,
        customer_group_key_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        cal_month_start_dt,

        SUM(total_net_cos) AS total_net_cos,
        SUM(total_sls_qty) AS total_sls_qty,
        SUM(total_net_cos) / NULLIF(SUM(total_sls_qty), 0) AS contract_price
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v5
    GROUP BY
        run_id,
        customer_group_key_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        cal_month_start_dt
),
last_month AS (
    SELECT
        run_id,
        customer_group_key_id,
        cust_prod_category,
        MAX(cal_month_start_dt) AS anchor_month
    FROM monthly_cat
    GROUP BY
        run_id,
        customer_group_key_id,
        cust_prod_category
),
agg AS (
    SELECT
        lm.run_id,
        lm.customer_group_key_id,
        lm.cust_prod_category,
        lm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN mc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN mc.cal_month_start_dt
        END) AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN mc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND mc.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN mc.cal_month_start_dt
        END) AS prior_12m_months,

        AVG(CASE
            WHEN mc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN mc.contract_price
        END) AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN mc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND mc.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN mc.contract_price
        END) AS prior_12m_avg_contract_price
    FROM last_month lm
    LEFT JOIN monthly_cat mc
      ON lm.run_id = mc.run_id
     AND lm.customer_group_key_id = mc.customer_group_key_id
     AND lm.cust_prod_category = mc.cust_prod_category
    GROUP BY
        lm.run_id,
        lm.customer_group_key_id,
        lm.cust_prod_category,
        lm.anchor_month
)
SELECT
    a.run_id,
    a.customer_group_key_id,
    a.cust_prod_category,
    a.anchor_month,

    CASE
        WHEN a.recent_12m_months >= 6
         AND a.prior_12m_months >= 6
         AND a.prior_12m_avg_contract_price IS NOT NULL
         AND a.prior_12m_avg_contract_price > 0
        THEN LEAST(
                GREATEST(
                    POWER(
                        a.recent_12m_avg_contract_price / a.prior_12m_avg_contract_price,
                        1.0 / 12.0
                    ) - 1,
                    -0.02
                ),
                0.02
             )
        ELSE 0
    END AS expected_monthly_trend_pct,

    CASE
        WHEN a.recent_12m_months >= 6 AND a.prior_12m_months >= 6
        THEN 'CUSTOMER_CATEGORY_24M_TREND'
        WHEN a.recent_12m_months >= 6
        THEN 'CUSTOMER_CATEGORY_RECENT_ONLY'
        ELSE 'CUSTOMER_CATEGORY_NO_SIGNAL'
    END AS fallback_source
FROM agg a
;


/* ---------------------------------------------------------------------
   STEP 5D: RUN SEGMENT + CLASS OF TRADE + CATEGORY FALLBACK
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_fallback_segment_category_v5 AS
WITH monthly_seg_cat AS (
    SELECT
        run_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        cal_month_start_dt,

        SUM(total_net_cos) AS total_net_cos,
        SUM(total_sls_qty) AS total_sls_qty,
        SUM(total_net_cos) / NULLIF(SUM(total_sls_qty), 0) AS contract_price
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v5
    GROUP BY
        run_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        cal_month_start_dt
),
last_month AS (
    SELECT
        run_id,
        cust_segment,
        acct_classification,
        cust_prod_category,
        MAX(cal_month_start_dt) AS anchor_month
    FROM monthly_seg_cat
    GROUP BY
        run_id,
        cust_segment,
        acct_classification,
        cust_prod_category
),
agg AS (
    SELECT
        lm.run_id,
        lm.cust_segment,
        lm.acct_classification,
        lm.cust_prod_category,
        lm.anchor_month,

        COUNT(DISTINCT CASE
            WHEN msc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN msc.cal_month_start_dt
        END) AS recent_12m_months,

        COUNT(DISTINCT CASE
            WHEN msc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND msc.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN msc.cal_month_start_dt
        END) AS prior_12m_months,

        AVG(CASE
            WHEN msc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -12)
            THEN msc.contract_price
        END) AS recent_12m_avg_contract_price,

        AVG(CASE
            WHEN msc.cal_month_start_dt > ADD_MONTHS(lm.anchor_month, -24)
             AND msc.cal_month_start_dt <= ADD_MONTHS(lm.anchor_month, -12)
            THEN msc.contract_price
        END) AS prior_12m_avg_contract_price
    FROM last_month lm
    LEFT JOIN monthly_seg_cat msc
      ON lm.run_id = msc.run_id
     AND lm.cust_segment = msc.cust_segment
     AND lm.acct_classification = msc.acct_classification
     AND lm.cust_prod_category = msc.cust_prod_category
    GROUP BY
        lm.run_id,
        lm.cust_segment,
        lm.acct_classification,
        lm.cust_prod_category,
        lm.anchor_month
)
SELECT
    a.run_id,
    a.cust_segment,
    a.acct_classification,
    a.cust_prod_category,
    a.anchor_month,

    CASE
        WHEN a.recent_12m_months >= 6
         AND a.prior_12m_months >= 6
         AND a.prior_12m_avg_contract_price IS NOT NULL
         AND a.prior_12m_avg_contract_price > 0
        THEN LEAST(
                GREATEST(
                    POWER(
                        a.recent_12m_avg_contract_price / a.prior_12m_avg_contract_price,
                        1.0 / 12.0
                    ) - 1,
                    -0.02
                ),
                0.02
             )
        ELSE 0
    END AS expected_monthly_trend_pct,

    CASE
        WHEN a.recent_12m_months >= 6 AND a.prior_12m_months >= 6
        THEN 'SEGMENT_CATEGORY_24M_TREND'
        WHEN a.recent_12m_months >= 6
        THEN 'SEGMENT_CATEGORY_RECENT_ONLY'
        ELSE 'SEGMENT_CATEGORY_NO_SIGNAL'
    END AS fallback_source
FROM agg a
;


/* ---------------------------------------------------------------------
   STEP 6: RUN-RESOLVED ASSUMPTIONS
   - Anchor = latest raw actual before jump-off
   - Trend priority:
       1) MATERIAL
       2) CUSTOMER_PRODUCT_GROUP
       3) CUSTOMER_CATEGORY
       4) SEGMENT_CATEGORY
       5) STATIC_NO_TREND
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v5 AS
SELECT
    e.run_id,
    e.jump_off_month,
    e.history_start_dt,
    e.history_end_dt,

    e.customer_group_key_id,
    e.mtrl_num,

    e.cust_segment,
    e.acct_classification,
    e.cust_prod_category,

    e.national_grp_id,
    e.national_grp_desc,
    e.customer_group_key_desc,

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

    ma.expected_monthly_trend_pct AS material_monthly_trend_pct,
    pg.expected_monthly_trend_pct AS product_group_monthly_trend_pct,
    cf.expected_monthly_trend_pct AS category_monthly_trend_pct,
    sc.expected_monthly_trend_pct AS segment_category_monthly_trend_pct,

    CASE
        WHEN ma.expected_monthly_trend_pct IS NOT NULL
         AND ma.anchor_month IS NOT NULL
        THEN ma.expected_monthly_trend_pct

        WHEN pg.expected_monthly_trend_pct IS NOT NULL
        THEN pg.expected_monthly_trend_pct

        WHEN cf.expected_monthly_trend_pct IS NOT NULL
        THEN cf.expected_monthly_trend_pct

        WHEN sc.expected_monthly_trend_pct IS NOT NULL
        THEN sc.expected_monthly_trend_pct

        ELSE 0
    END AS resolved_monthly_trend_pct,

    CASE
        WHEN ma.expected_monthly_trend_pct IS NOT NULL
         AND ma.anchor_month IS NOT NULL
        THEN 'MATERIAL'

        WHEN pg.expected_monthly_trend_pct IS NOT NULL
        THEN 'CUSTOMER_PRODUCT_GROUP'

        WHEN cf.expected_monthly_trend_pct IS NOT NULL
        THEN 'CUSTOMER_CATEGORY'

        WHEN sc.expected_monthly_trend_pct IS NOT NULL
        THEN 'SEGMENT_CATEGORY'

        ELSE 'STATIC_NO_TREND'
    END AS trend_source

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v5 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v5 la
  ON e.run_id = la.run_id
 AND e.customer_group_key_id = la.customer_group_key_id
 AND e.mtrl_num = la.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v5 ma
  ON e.run_id = ma.run_id
 AND e.customer_group_key_id = ma.customer_group_key_id
 AND e.mtrl_num = ma.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_fallback_product_group_v5 pg
  ON e.run_id = pg.run_id
 AND e.customer_group_key_id = pg.customer_group_key_id
 AND e.final_product_group = pg.final_product_group
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_fallback_category_v5 cf
  ON e.run_id = cf.run_id
 AND e.customer_group_key_id = cf.customer_group_key_id
 AND e.cust_prod_category = cf.cust_prod_category
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_fallback_segment_category_v5 sc
  ON e.run_id = sc.run_id
 AND e.cust_segment = sc.cust_segment
 AND e.acct_classification = sc.acct_classification
 AND e.cust_prod_category = sc.cust_prod_category
WHERE
    e.is_eligible_for_run = 1
    AND la.anchor_contract_price IS NOT NULL
;


/* ---------------------------------------------------------------------
   STEP 7: FUTURE ACTUAL MONTHS FOR BACKTEST
   - Uses actual observed months after jump-off
   - Limited to 60 months forward
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v5 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.customer_group_key_id,
    ra.mtrl_num,
    b.cal_month_start_dt AS forecast_month,
    CAST(months_between(b.cal_month_start_dt, ra.jump_off_month) AS INT) + 1 AS forecast_horizon_month_num,
    DATE_FORMAT(b.cal_month_start_dt, 'yyyy-MM') AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v5 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v5 b
  ON ra.customer_group_key_id = b.customer_group_key_id
 AND ra.mtrl_num = b.mtrl_num
 AND b.cal_month_start_dt >= ra.jump_off_month
 AND b.cal_month_start_dt < ADD_MONTHS(ra.jump_off_month, 60)
;


/* ---------------------------------------------------------------------
   STEP 8: FORECASTED CONTRACT PRICE
   - Forecast from anchor price using resolved monthly trend
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v5 AS
SELECT
    ra.run_id,
    ra.jump_off_month,
    ra.history_start_dt,
    ra.history_end_dt,

    ra.customer_group_key_id,
    ra.mtrl_num,

    ra.cust_segment,
    ra.acct_classification,
    ra.cust_prod_category,

    ra.national_grp_id,
    ra.national_grp_desc,
    ra.customer_group_key_desc,

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

    ra.material_monthly_trend_pct,
    ra.product_group_monthly_trend_pct,
    ra.category_monthly_trend_pct,
    ra.segment_category_monthly_trend_pct,

    ra.resolved_monthly_trend_pct,
    ra.trend_source,

    fam.forecast_month,
    fam.forecast_horizon_month_num,
    fam.forecast_year_month,

    CASE
        WHEN ra.anchor_contract_price IS NULL THEN NULL
        ELSE GREATEST(
            ra.anchor_contract_price * POWER(
                1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                fam.forecast_horizon_month_num
            ),
            0
        )
    END AS forecasted_contract_price

FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v5 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v5 fam
  ON ra.run_id = fam.run_id
 AND ra.customer_group_key_id = fam.customer_group_key_id
 AND ra.mtrl_num = fam.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 9: EVALUATION DETAIL
   - Compares forecast vs actual contract price
   - Uses actual qty to compute forecast dollars
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v5 AS
WITH joined AS (
    SELECT
        f.run_id,
        f.jump_off_month,
        f.customer_group_key_id,
        f.mtrl_num,
        f.forecast_month,
        f.forecast_horizon_month_num,
        f.forecast_year_month,

        f.cust_segment,
        f.acct_classification,
        f.cust_prod_category,

        f.national_grp_id,
        f.national_grp_desc,
        f.customer_group_key_desc,

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

        f.resolved_monthly_trend_pct,
        f.trend_source,
        f.forecasted_contract_price,

        a.contract_price AS actual_contract_price,
        a.account_class_cd as account_class_cd,
        a.wac_weighted AS actual_wac_weighted,
        a.wac_spread AS actual_wac_spread,
        a.total_sls_qty AS actual_sls_qty,
        a.total_net_cos AS actual_net_cos
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v5 f
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v5 a
      ON f.customer_group_key_id = a.customer_group_key_id
     AND f.mtrl_num = a.mtrl_num
     AND f.forecast_month = a.cal_month_start_dt
),
calc AS (
    SELECT
        j.*,

        /* dollars using actual qty to isolate price forecast error */
        j.forecasted_contract_price * j.actual_sls_qty AS forecasted_dollars,
        j.actual_contract_price * j.actual_sls_qty AS actual_dollars,

        /* price error */
        (j.forecasted_contract_price - j.actual_contract_price) AS error_contract_price,
        ABS(j.forecasted_contract_price - j.actual_contract_price) AS ae_contract_price,

        CASE
            WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
            THEN (j.forecasted_contract_price - j.actual_contract_price) / j.actual_contract_price
            ELSE NULL
        END AS bias_contract_price,

        CASE
            WHEN j.actual_contract_price IS NOT NULL AND j.actual_contract_price <> 0
            THEN ABS(j.forecasted_contract_price - j.actual_contract_price) / ABS(j.actual_contract_price)
            ELSE NULL
        END AS ape_contract_price,

        /* dollar error */
        ((j.forecasted_contract_price * j.actual_sls_qty) - (j.actual_contract_price * j.actual_sls_qty)) AS error_dollars,
        ABS((j.forecasted_contract_price * j.actual_sls_qty) - (j.actual_contract_price * j.actual_sls_qty)) AS ae_dollars,

        CASE
            WHEN (j.actual_contract_price * j.actual_sls_qty) IS NOT NULL
             AND (j.actual_contract_price * j.actual_sls_qty) <> 0
            THEN (
                (j.forecasted_contract_price * j.actual_sls_qty) - (j.actual_contract_price * j.actual_sls_qty)
            ) / (j.actual_contract_price * j.actual_sls_qty)
            ELSE NULL
        END AS bias_dollars,

        CASE
            WHEN (j.actual_contract_price * j.actual_sls_qty) IS NOT NULL
             AND (j.actual_contract_price * j.actual_sls_qty) <> 0
            THEN ABS(
                (j.forecasted_contract_price * j.actual_sls_qty) - (j.actual_contract_price * j.actual_sls_qty)
            ) / ABS(j.actual_contract_price * j.actual_sls_qty)
            ELSE NULL
        END AS ape_dollars,

        /* optional implied spread from forecast using actual WAC */
        CASE
            WHEN j.actual_wac_weighted IS NOT NULL AND j.actual_wac_weighted <> 0
            THEN (j.forecasted_contract_price / j.actual_wac_weighted) - 1
            ELSE NULL
        END AS implied_forecast_wac_spread

    FROM joined j
),
weighted AS (
    SELECT
        c.*,

        CASE
            WHEN SUM(ABS(c.error_dollars)) OVER (PARTITION BY c.run_id) <> 0
            THEN ABS(c.error_dollars) / SUM(ABS(c.error_dollars)) OVER (PARTITION BY c.run_id)
            ELSE NULL
        END AS weighted_percent_error,

        CASE
            WHEN SUM(ABS(c.actual_dollars)) OVER (PARTITION BY c.run_id) <> 0
            THEN ABS(c.actual_dollars) / SUM(ABS(c.actual_dollars)) OVER (PARTITION BY c.run_id)
            ELSE NULL
        END AS revenue_share

    FROM calc c
),
ranked AS (
    SELECT
        w.*,
        NTILE(5) OVER (
            PARTITION BY w.run_id
            ORDER BY ABS(w.actual_dollars) DESC NULLS LAST
        ) AS revenue_quintile_desc
    FROM weighted w
)
SELECT
    r.*,

    CASE
        WHEN r.revenue_quintile_desc = 1 THEN 'TOP_20'
        WHEN r.revenue_quintile_desc IN (2,3,4) THEN 'MIDDLE_60'
        WHEN r.revenue_quintile_desc = 5 THEN 'BOTTOM_20'
        ELSE 'UNKNOWN'
    END AS materiality_band,

    CASE
        WHEN r.revenue_quintile_desc = 1 THEN 0.03
        WHEN r.revenue_quintile_desc IN (2,3,4) THEN 0.10
        WHEN r.revenue_quintile_desc = 5 THEN 0.20
        ELSE NULL
    END AS materiality_threshold_pct,

    CASE
        WHEN r.ape_contract_price IS NOT NULL AND r.ape_contract_price < 0.20 THEN 1
        WHEN r.ape_contract_price IS NOT NULL THEN 0
        ELSE NULL
    END AS pass_flag_vs_actual_error_threshold,

    CASE
        WHEN r.ape_dollars IS NOT NULL
         AND (
                (r.revenue_quintile_desc = 1 AND r.ape_dollars <= 0.03) OR
                (r.revenue_quintile_desc IN (2,3,4) AND r.ape_dollars <= 0.10) OR
                (r.revenue_quintile_desc = 5 AND r.ape_dollars <= 0.20)
             )
        THEN 1
        WHEN r.ape_dollars IS NOT NULL THEN 0
        ELSE NULL
    END AS pass_flag_vs_materiality_threshold,

    CASE
        WHEN r.ape_dollars IS NOT NULL
         AND (
                (r.revenue_quintile_desc = 1 AND r.ape_dollars > 0.03) OR
                (r.revenue_quintile_desc IN (2,3,4) AND r.ape_dollars > 0.10) OR
                (r.revenue_quintile_desc = 5 AND r.ape_dollars > 0.20)
             )
         AND ABS(r.actual_dollars) IS NOT NULL
         AND ABS(r.actual_dollars) > 0
        THEN 'CRITICAL'
        WHEN r.ape_contract_price IS NOT NULL AND r.ape_contract_price > 0.20
        THEN 'MODERATE'
        ELSE 'PASS'
    END AS review_priority,

    CASE
        WHEN r.forecasted_contract_price > 3 * r.anchor_contract_price THEN 1
        ELSE 0
    END AS forecast_explosion_flag

FROM ranked r
WHERE forecast_month IS NOT NULL
;


/* ---------------------------------------------------------------------
   STEP 10: EVAL SUMMARY BY RUN
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_eval_summary_run_v5 AS
SELECT
    run_id,

    COUNT(*) AS row_cnt,
    COUNT(DISTINCT CONCAT_WS('|', customer_group_key_id, mtrl_num)) AS series_cnt,

    AVG(ape_contract_price) AS mape_contract_price,
    AVG(ape_dollars) AS mape_dollars,

    SUM(ae_contract_price) / NULLIF(SUM(ABS(actual_contract_price)), 0) AS wape_contract_price,
    SUM(ae_dollars) / NULLIF(SUM(ABS(actual_dollars)), 0) AS wape_dollars,

    AVG(bias_contract_price) AS avg_bias_contract_price,
    AVG(bias_dollars) AS avg_bias_dollars,

    COUNT_IF(pass_flag_vs_actual_error_threshold = 1) AS pass_cnt_price,
    COUNT_IF(pass_flag_vs_actual_error_threshold = 0) AS fail_cnt_price,

    COUNT_IF(pass_flag_vs_materiality_threshold = 1) AS pass_cnt_materiality,
    COUNT_IF(pass_flag_vs_materiality_threshold = 0) AS fail_cnt_materiality,

    COUNT_IF(forecast_explosion_flag = 1) AS explosion_row_cnt

FROM uspd_analytics_den.analytics_gold.contract_price_bt_eval_detail_v5
GROUP BY
    run_id
;
