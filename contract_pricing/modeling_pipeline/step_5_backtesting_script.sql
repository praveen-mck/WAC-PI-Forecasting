/* =====================================================================
   CONTRACT PRICE BACKTEST PIPELINE (v18) — UPDATED
   ---------------------------------------------------------------------
   Changes from original:

   STEP 5 (contract_price_bt_material_assumptions_v18):
     Replaced self-contained 12m-window / trend=0 logic with a direct
     JOIN to contract_price_material_assumptions_v18. This passes the
     correct forecast_start_contract_price, expected_monthly_trend_pct,
     assigned_trend_method, and forecast_start_price_source from the
     global assumptions table (Step 4 of the modeling pipeline) into
     the backtest. The original never read from that table, so all
     AVG_YOY_PROMOTED, G5 guard, and ratio guard fixes were silently
     ignored.

   STEP 6 (contract_price_bt_resolved_assumptions_v18):
     - resolved_monthly_trend_pct: was hardcoded 0, now ma.expected_monthly_trend_pct
     - trend_source: was hardcoded 'STATIC_NO_TREND', now ma.assigned_trend_method
     - recent_12m_months / prior_12m_months / latest_12_observed_months
       removed; replaced with recent_6m_months / latest_6_observed_months
       (matching the output columns of the updated Step 5)

   STEP 8 (contract_price_bt_forecasted_v18):
     - POWER exponent: was forecast_horizon_month_num (monthly exponent
       on a per-quarter rate → 3x over-compounding). Fixed to
       CEIL(forecast_horizon_month_num / 3.0) to match Step 4 formula:
       price * (1 + trend)^CEIL(months_ahead/3)
     - ra.recent_12m_months / ra.prior_12m_months / ra.latest_12_observed_months
       updated to ra.recent_6m_months / ra.latest_6_observed_months

   Steps 0–4 and 7: unchanged.
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: BACKTEST RUNS — unchanged
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_runs_v18 AS
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
   STEP 1: GLOBAL SERIES PROFILE — unchanged
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v18 AS
WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v18
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
        MAX(MODEL_TIER)                 AS MODEL_TIER,
        MAX(sap_months)                 AS sap_months,
        MAX(l2_months)                  AS l2_months,
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
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num
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
LEFT JOIN first_row f ON a.HYBRID_MODEL_KEY_3T = f.HYBRID_MODEL_KEY_3T AND a.mtrl_num = f.mtrl_num
LEFT JOIN last_row  l ON a.HYBRID_MODEL_KEY_3T = l.HYBRID_MODEL_KEY_3T AND a.mtrl_num = l.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 2: RUN ELIGIBILITY — unchanged
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v18 AS
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
    CASE
        WHEN sp.first_month IS NOT NULL AND sp.first_month <= r.history_end_dt THEN 1
        ELSE 0
    END AS is_eligible_for_run,
    CASE
        WHEN sp.first_month IS NULL            THEN 'NO_HISTORY'
        WHEN sp.first_month > r.history_end_dt THEN 'NOT_LAUNCHED_YET'
        ELSE 'ELIGIBLE'
    END AS data_coverage_flag
FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v18 r
CROSS JOIN uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v18 sp
;


/* ---------------------------------------------------------------------
   STEP 3: RUN-SPECIFIC LAST ACTUAL (RAW) — unchanged
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v18 AS
WITH eligible AS (
    SELECT * FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v18
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
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v18 b
      ON e.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
     AND e.mtrl_num = b.mtrl_num
     AND b.cal_month_start_dt <= e.history_end_dt
)
SELECT
    run_id, jump_off_month, history_end_dt,
    HYBRID_MODEL_KEY_3T, mtrl_num,
    cal_month_start_dt AS anchor_month,
    contract_price     AS anchor_contract_price,
    wac_weighted       AS anchor_wac_weighted,
    wac_spread         AS anchor_wac_spread,
    total_sls_qty      AS anchor_total_sls_qty,
    total_net_cos      AS anchor_total_net_cos
FROM raw_hist
WHERE rn = 1
;


/* ---------------------------------------------------------------------
   STEP 4: RUN-SPECIFIC CLEAN HIST PANEL — unchanged
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_hist_clean_v18 AS
SELECT
    e.run_id, e.jump_off_month, e.lookback_years, e.history_start_dt, e.history_end_dt,
    e.HYBRID_MODEL_KEY_3T, e.mtrl_num,
    e.MODEL_TIER, e.sap_months, e.l2_months,
    e.cust_segment, e.acct_classification, e.cust_prod_category,
    e.national_grp_id, e.national_grp_desc,
    e.mtrl_nme_nvgton, e.ndc_num,
    e.product_family, e.therapeutic_class, e.manufacturer_id, e.manufacturer_name,
    e.final_product_group, e.final_product_group_level,
    t.cal_month_start_dt,
    t.total_net_cos, t.total_sls_qty, t.contract_price,
    t.wac_weighted, t.wac_spread,
    t.mom_contract_price_change_pct,
    t.contract_price_change_outlier_flag,
    t.series_month_index,
    t.series_valid_month_count,
    t.sap_to_l2_coverage_ratio
FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v18 e
JOIN uspd_analytics_den.analytics_gold.contract_price_training_clean_v18 t
  ON e.HYBRID_MODEL_KEY_3T = t.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num = t.mtrl_num
 AND t.cal_month_start_dt >= e.history_start_dt
 AND t.cal_month_start_dt <= e.history_end_dt
WHERE e.is_eligible_for_run = 1
  AND t.include_for_modeling_flag = 1
;


/* ---------------------------------------------------------------------
   STEP 5: RUN MATERIAL-LEVEL ASSUMPTIONS — UPDATED
   ---------------------------------------------------------------------
   Replaces the original self-contained 12m-window / trend=0 logic with
   a direct JOIN to contract_price_material_assumptions_v18 so that
   AVG_YOY_PROMOTED, G5 guard, ratio guard fixes, and all other v18
   assumptions flow into the backtest.

   Join is on HYBRID_MODEL_KEY_3T + mtrl_num only (no run_id) because
   the global assumptions table is not run-specific. Every run for a
   given key receives the same modeling assumptions, which is correct —
   the assumptions table represents the current training state.

   Fallback: keys missing from the global assumptions table fall back
   to the run-specific anchor price with zero trend.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v18 AS
SELECT
    e.run_id,
    e.HYBRID_MODEL_KEY_3T,
    e.mtrl_num,
    la.anchor_month,

    -- Price baseline from global assumptions_v18
    -- (6m window, ratio-guard fixed, G5 guard applied)
    COALESCE(a.forecast_start_contract_price,  la.anchor_contract_price) AS forecast_start_contract_price,
    COALESCE(a.forecast_start_wac_spread,      la.anchor_wac_spread)     AS forecast_start_wac_spread,

    -- Trend from global assumptions_v18
    -- (AVG_YOY_PROMOTED, SIGN_ONLY_025PCT, REGRESSION, NO_TREND, etc.)
    COALESCE(a.expected_monthly_trend_pct, 0)           AS expected_monthly_trend_pct,
    COALESCE(a.monthly_trend_pct_raw,      0)           AS monthly_trend_pct_raw,

    -- Method and source labels
    COALESCE(a.assigned_trend_method,       'NO_TREND')            AS assigned_trend_method,
    COALESCE(a.forecast_start_price_source, 'NO_HISTORY_AVAILABLE') AS forecast_start_price_source,

    -- History depth diagnostics (6m windows, consistent with Step 4)
    a.recent_6m_months,
    a.latest_6_observed_months,

    -- Sparse confidence re-derived from 6m observed months
    CASE
        WHEN COALESCE(a.latest_6_observed_months, 0) >= 6 THEN 'PRICE_6MO_AVG'
        WHEN COALESCE(a.latest_6_observed_months, 0) >= 3 THEN 'PRICE_3_TO_5_MO_AVG'
        WHEN COALESCE(a.latest_6_observed_months, 0) >= 1 THEN 'PRICE_LAST_OBSERVED'
        ELSE                                                    'NO_PRICE_AVAILABLE'
    END AS sparse_price_confidence,

    CASE
        WHEN COALESCE(a.latest_6_observed_months, 0) < 6 THEN 1
        ELSE                                                   0
    END AS is_sparse_price_flag

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v18 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v18 la
  ON e.run_id              = la.run_id
 AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = la.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v18 a
  ON e.HYBRID_MODEL_KEY_3T = a.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = a.mtrl_num
WHERE e.is_eligible_for_run = 1
;


/* ---------------------------------------------------------------------
   STEP 6: RUN-RESOLVED ASSUMPTIONS — UPDATED
   ---------------------------------------------------------------------
   Changes vs original:
   - resolved_monthly_trend_pct: was 0, now ma.expected_monthly_trend_pct
   - trend_source: was 'STATIC_NO_TREND', now ma.assigned_trend_method
   - Diagnostic cols updated: recent_12m_months / prior_12m_months /
     latest_12_observed_months → recent_6m_months / latest_6_observed_months
     (matching updated Step 5 output columns)
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v18 AS
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

    -- Updated diagnostic columns (6m windows from assumptions_v18)
    ma.recent_6m_months,
    ma.latest_6_observed_months,

    -- UPDATED: pass trend through from assumptions_v18
    -- was: 0 AS resolved_monthly_trend_pct
    -- was: 'STATIC_NO_TREND' AS trend_source
    ma.expected_monthly_trend_pct                       AS resolved_monthly_trend_pct,
    ma.assigned_trend_method                            AS trend_source

FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v18 e
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v18 la
  ON e.run_id              = la.run_id
 AND e.HYBRID_MODEL_KEY_3T = la.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = la.mtrl_num
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v18 ma
  ON e.run_id              = ma.run_id
 AND e.HYBRID_MODEL_KEY_3T = ma.HYBRID_MODEL_KEY_3T
 AND e.mtrl_num             = ma.mtrl_num
WHERE e.is_eligible_for_run = 1
  AND la.anchor_contract_price IS NOT NULL
;


/* ---------------------------------------------------------------------
   STEP 7: FUTURE ACTUAL MONTHS — unchanged
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v18 AS
SELECT DISTINCT
    ra.run_id,
    ra.jump_off_month,
    ra.HYBRID_MODEL_KEY_3T,
    ra.mtrl_num,
    b.cal_month_start_dt                                AS forecast_month,
    CAST(months_between(b.cal_month_start_dt, ra.jump_off_month) AS INT) + 1
                                                        AS forecast_horizon_month_num,
    DATE_FORMAT(b.cal_month_start_dt, 'yyyy-MM')        AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v18 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v18 b
  ON ra.HYBRID_MODEL_KEY_3T = b.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = b.mtrl_num
 AND b.cal_month_start_dt >= ra.jump_off_month
 AND b.cal_month_start_dt <  ADD_MONTHS(ra.jump_off_month, 60)
;


/* ---------------------------------------------------------------------
   STEP 8: FORECASTED CONTRACT PRICE — UPDATED
   ---------------------------------------------------------------------
   Changes vs original:
   - POWER exponent: was fam.forecast_horizon_month_num (treated trend
     as monthly rate, causing 3x over-compounding on a per-quarter rate).
     Fixed to CEIL(fam.forecast_horizon_month_num / 3.0) to match the
     Step 4 compounding formula: price * (1+trend)^CEIL(months_ahead/3)
   - Diagnostic columns updated:
     ra.recent_12m_months  → ra.recent_6m_months
     ra.prior_12m_months   → removed
     ra.latest_12_observed_months → ra.latest_6_observed_months
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v18 AS
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

    -- Updated diagnostic columns (6m windows)
    ra.recent_6m_months,
    ra.latest_6_observed_months,

    ra.resolved_monthly_trend_pct,
    ra.trend_source,

    fam.forecast_month,
    fam.forecast_horizon_month_num,
    fam.forecast_year_month,

    -- UPDATED: exponent is CEIL(months/3) to match Step 4 per-quarter rate.
    -- Original used forecast_horizon_month_num which over-compounded 3x.
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

FROM uspd_analytics_den.analytics_gold.contract_price_bt_resolved_assumptions_v18 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_future_actual_months_v18 fam
  ON ra.run_id              = fam.run_id
 AND ra.HYBRID_MODEL_KEY_3T = fam.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = fam.mtrl_num
LEFT JOIN (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        MAX(WAC)               AS WAC,
        MAX(TOTAL_NET_REVENUE) AS total_net_revenue
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v18
    GROUP BY HYBRID_MODEL_KEY_3T, mtrl_num
) src
  ON ra.HYBRID_MODEL_KEY_3T = src.HYBRID_MODEL_KEY_3T
 AND ra.mtrl_num             = src.mtrl_num
;