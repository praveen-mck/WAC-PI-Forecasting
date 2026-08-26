-- =========================================================
-- STEP 3a: BACKTEST PREREQUISITE TABLES v23
--
-- Builds the four tables that step_4a and step_5a depend on.
-- Run after steps 0–3; before step_4a.
--
-- Prerequisites:
--   step_0 → contract_price_bt_runs_v23
--   step_1 → contract_price_modeling_base_v23
--   step_2 → contract_price_history_profile_v23
--
-- Tables created (in order):
--   1. contract_price_bt_series_profile_v23
--        One row per series (groupby_key). Joins history_profile
--        (step 2) with modeling_base (step 1) to pick up WAC and
--        Total_Net_Revenue, which are not aggregated in step 2.
--
--   2. contract_price_bt_run_eligibility_v23
--        One row per run × series. CROSS JOIN of runs config with
--        the series profile. Sets is_eligible_for_run = 1 when
--        the series has any history before the run's history_end_dt.
--        This is the primary driver of all downstream bt joins.
--
--   3. contract_price_bt_last_actual_v23
--        One row per run × series. The most recent observed
--        (non-excluded) contract price within the run's training
--        window. Used as the anchor price for forecasting.
--
--   4. contract_price_bt_latest_obs_v23
--        One row per run × series. Average contract price and WAC
--        spread over the 6 most recent observed months in the
--        training window.
-- =========================================================


-- =====================================================================
-- TABLE 1: SERIES PROFILE
-- Grain: one row per groupby_key (series-level, run-agnostic).
-- Joins history_profile (step 2) with modeling_base (step 1) to
-- retrieve WAC and Total_Net_Revenue via MAX() across all months.
-- All other attributes come from step 2, which already aggregates
-- them correctly.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v23 AS
SELECT
    hp.groupby_key,
    hp.sap_cust_num_trim,
    hp.mtrl_num,
    hp.cust_segment,
    hp.acct_classification,
    hp.cust_prod_category,
    hp.national_grp_id,
    hp.national_grp_desc,
    hp.common_grp_id,
    hp.common_grp_desc,
    hp.subset_l2_id_resolved,
    hp.mtrl_nme_nvgton,
    hp.ndc_num,
    hp.product_family,
    hp.therapeutic_class,
    hp.manufacturer_id,
    hp.manufacturer_name,
    hp.final_product_group,
    MAX(b.final_product_group_level)    AS final_product_group_level,
    MAX(b.WAC)                          AS WAC,
    MAX(b.TOTAL_NET_REVENUE)            AS Total_Net_Revenue,
    hp.first_month,
    hp.last_month                       AS last_actual_month,
    hp.first_contract_price,
    hp.last_contract_price              AS last_actual_contract_price,
    hp.last_wac_spread                  AS last_actual_wac_spread,
    hp.top_100_brand_flag,
    hp.brand_wac_rank
FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v23 hp
LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
  ON hp.groupby_key = b.groupby_key
GROUP BY
    hp.groupby_key, hp.sap_cust_num_trim, hp.mtrl_num,
    hp.cust_segment, hp.acct_classification, hp.cust_prod_category,
    hp.national_grp_id, hp.national_grp_desc, hp.common_grp_id, hp.common_grp_desc,
    hp.subset_l2_id_resolved, hp.mtrl_nme_nvgton, hp.ndc_num, hp.product_family,
    hp.therapeutic_class, hp.manufacturer_id, hp.manufacturer_name, hp.final_product_group,
    hp.first_month, hp.last_month, hp.first_contract_price, hp.last_contract_price,
    hp.last_wac_spread, hp.top_100_brand_flag, hp.brand_wac_rank
;


-- =====================================================================
-- TABLE 2: RUN ELIGIBILITY
-- Grain: one row per run_id × groupby_key.
-- CROSS JOIN of every run with every series. Sets eligibility flags
-- based on whether the series launched before the run's history window.
--
-- is_eligible_for_run = 1 when first_month <= history_end_dt
--   (series existed before the run's training cutoff)
-- data_coverage_flag distinguishes the ineligible reasons:
--   NO_HISTORY      — series has no data at all
--   NOT_LAUNCHED_YET — series launched after the run's cutoff
--   ELIGIBLE        — series has qualifying history
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v23 AS
SELECT
    r.run_id,
    r.jump_off_month,
    r.lookback_years,
    r.history_start_dt,
    r.history_end_dt,
    sp.groupby_key,
    sp.sap_cust_num_trim,
    sp.mtrl_num,
    sp.cust_segment,
    sp.acct_classification,
    sp.cust_prod_category,
    sp.national_grp_id,
    sp.national_grp_desc,
    sp.common_grp_id,
    sp.common_grp_desc,
    sp.subset_l2_id_resolved,
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
        WHEN sp.first_month IS NOT NULL
         AND sp.first_month <= r.history_end_dt THEN 1
        ELSE 0
    END                                                         AS is_eligible_for_run,
    CASE
        WHEN sp.first_month IS NULL            THEN 'NO_HISTORY'
        WHEN sp.first_month > r.history_end_dt THEN 'NOT_LAUNCHED_YET'
        ELSE 'ELIGIBLE'
    END                                                         AS data_coverage_flag
FROM uspd_analytics_den.analytics_gold.contract_price_bt_runs_v23 r
CROSS JOIN uspd_analytics_den.analytics_gold.contract_price_bt_series_profile_v23 sp
;


-- =====================================================================
-- TABLE 3: LAST ACTUAL (ANCHOR)
-- Grain: one row per run_id × groupby_key (eligible series only).
-- The most recent non-excluded observed contract price within the
-- run's training window. This becomes the anchor price that all
-- forecast methods compound forward from.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23 AS
WITH eligible AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v23
    WHERE is_eligible_for_run = 1
),
raw_hist AS (
    SELECT
        e.run_id,
        e.jump_off_month,
        e.history_end_dt,
        b.groupby_key,
        b.sap_cust_num_trim,
        b.mtrl_num,
        b.cal_month_start_dt,
        b.contract_price,
        b.wac_weighted,
        b.wac_spread,
        b.total_sls_qty,
        b.total_net_cos,
        ROW_NUMBER() OVER (
            PARTITION BY e.run_id, b.groupby_key
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON e.groupby_key = b.groupby_key
     AND b.cal_month_start_dt     <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
)
SELECT
    run_id,
    jump_off_month,
    history_end_dt,
    groupby_key,
    sap_cust_num_trim,
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


-- =====================================================================
-- TABLE 4: LATEST 6 OBSERVED MONTHS
-- Grain: one row per run_id × groupby_key (eligible series only).
-- Summary of the 6 most recent non-excluded months of price/spread
-- history within the training window. Used in step_4a to assess
-- recent pricing stability.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_latest_obs_v23 AS
WITH eligible AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v23
    WHERE is_eligible_for_run = 1
),
ranked_obs AS (
    SELECT
        e.run_id,
        e.groupby_key,
        b.cal_month_start_dt,
        b.contract_price,
        b.total_net_cos,
        b.total_sls_qty,
        b.wac_spread,
        ROW_NUMBER() OVER (
            PARTITION BY e.run_id, e.groupby_key
            ORDER BY b.cal_month_start_dt DESC
        ) AS obs_rn
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON e.groupby_key = b.groupby_key
     AND b.cal_month_start_dt     <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
)
SELECT
    run_id,
    groupby_key,
    COUNT(DISTINCT cal_month_start_dt)          AS latest_6_observed_months,
    NULLIF(SUM(total_net_cos), 0)
        / NULLIF(SUM(total_sls_qty), 0)         AS latest_6_observed_avg_contract_price,
    AVG(wac_spread)                             AS latest_6_observed_avg_wac_spread
FROM ranked_obs
WHERE obs_rn <= 6
GROUP BY run_id, groupby_key
;