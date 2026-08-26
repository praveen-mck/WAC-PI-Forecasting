-- =========================================================
-- STEP 7a: BACKTEST FORECAST OUTPUT FORMATTED v1
--
-- Final consumption table. Filters contract_price_bt_forecasted_v23
-- (step 6a) to the two operational forecast runs and shapes into
-- the standard output schema used by downstream consumers.
--
-- Run filter: BT_2025_08 (consolidated view, 5-yr horizon)
--             BT_2026_07 (Odyssey, 5-yr horizon)
-- Horizon:    60 months (hardcoded in step 6a join condition)
--
-- To include a different run: add it to the IN list below.
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_forecast_output_monthly_v1 AS

-- BT_2025_08 uses a one-time override timestamp (the model was locked on 2026-06-29).
-- BT_2026_07 uses the actual run timestamp.
WITH ts AS (
    SELECT TO_TIMESTAMP('2026-06-29T19:05:46.782+00:00') AS override_ts
),

latest_actuals AS (
    SELECT
        groupby_key,
        wac_mom_decrease_flag           AS wac_price_decrease_flag,
        wac_5pct_drop_flag              AS wac_significant_decrease_flag,
        contract_price_drop_30pct_flag,
        contract_price_inc_30pct_flag
    FROM (
        SELECT
            groupby_key,
            wac_mom_decrease_flag,
            wac_5pct_drop_flag,
            contract_price_drop_30pct_flag,
            contract_price_inc_30pct_flag,
            ROW_NUMBER() OVER (
                PARTITION BY groupby_key
                ORDER BY cal_month_start_dt DESC
            ) AS rn
        FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
        WHERE exclude_from_actuals_flag = 0
    ) x
    WHERE rn = 1
)

SELECT
    -- Load metadata
    -- BT_2025_08: locked to 2026-06-29 (model frozen date)
    -- BT_2026_07: stamped at actual run time
    CASE WHEN f.run_id = 'BT_2025_08' THEN ts.override_ts
         ELSE CURRENT_TIMESTAMP()
    END                                                     AS LOAD_TS,
    CASE WHEN f.run_id = 'BT_2025_08' THEN TO_DATE(ts.override_ts)
         ELSE TO_DATE(CURRENT_TIMESTAMP())
    END                                                     AS LOAD_DATE,
    CASE WHEN f.run_id = 'BT_2025_08' THEN DATE_FORMAT(ts.override_ts, 'HH:mm')
         ELSE DATE_FORMAT(CURRENT_TIMESTAMP(), 'HH:mm')
    END                                                     AS LOAD_TIME,
    CASE WHEN f.run_id = 'BT_2025_08' THEN DATE_FORMAT(ts.override_ts, 'yyyy-MM')
         ELSE DATE_FORMAT(CURRENT_TIMESTAMP(), 'yyyy-MM')
    END                                                     AS LOAD_YEAR_MONTH,

    -- Run identity — which jump-off this forecast came from
    f.run_id                                                AS RUN_ID,

    -- Series key
    f.groupby_key,

    -- Forecast origin / horizon
    DATE_FORMAT(f.jump_off_month, 'yyyy-MM')                AS FCST_ORIGIN_YEAR_MONTH,
    f.forecast_horizon_month_num                            AS FORECAST_HORIZON_MONTH_NUM,
    f.forecast_year_month                                   AS FORECAST_CAL_YEAR_MONTH,
    -- FORECAST_FISCAL_YEAR_MONTH: McKesson FY starts April 1.
    -- FY = calendar year + 1 for months Apr–Dec, calendar year for Jan–Mar.
    CONCAT(
        'FY',
        CASE WHEN MONTH(f.forecast_month) >= 4
             THEN YEAR(f.forecast_month) + 1
             ELSE YEAR(f.forecast_month)
        END,
        '-',
        DATE_FORMAT(f.forecast_month, 'MM')
    )                                                       AS FORECAST_FISCAL_YEAR_MONTH,

    -- Product identifiers
    f.cust_prod_category                                    AS SLS_CTGRY_PRC_PROD_GRP,
    f.ndc_num                                               AS NDC_NUM,
    f.mtrl_num                                              AS MTRL_NUM,

    -- Customer identifiers
    f.common_grp_id                                         AS COMMON_GRP_ID,
    f.common_grp_desc                                       AS COMMON_GRP_NAME,
    -- f.subset_l2_id_resolved                              AS SUBSET_L2_ID,
    f.sap_cust_num_trim                                     AS SAP_CUST_NUM,
    f.cust_segment                                          AS CUST_SEGMENT,
    f.acct_classification                                   AS ACCT_CLASSIFICATION,
    f.national_grp_id                                       AS NATIONAL_GRP_ID,
    -- f.national_grp_desc                                  AS NATIONAL_GRP_DESC,

    -- Manufacturer / product descriptors
    f.manufacturer_id                                       AS MANUFACTURER_ID,
    -- f.mtrl_nme_nvgton                                    AS MTRL_NME_NVGTON,
    -- f.product_family                                     AS PRODUCT_FAMILY,
    -- f.therapeutic_class                                  AS THERAPEUTIC_CLASS,
    -- f.final_product_group                                AS FINAL_PRODUCT_GROUP,
    -- f.final_product_group_level                          AS FINAL_PRODUCT_GROUP_LEVEL,

    -- Anchor / assumptions context
    -- f.anchor_month                                       AS ANCHOR_MONTH,
    -- f.anchor_contract_price                              AS ANCHOR_CONTRACT_PRICE,
    -- f.anchor_wac_spread                                  AS ANCHOR_WAC_SPREAD,
    -- f.forecast_start_contract_price                      AS FORECAST_START_CONTRACT_PRICE,
    -- f.forecast_start_price_source                        AS FORECAST_START_PRICE_SOURCE,
    -- f.sparse_price_confidence                            AS SPARSE_PRICE_CONFIDENCE,
    -- f.is_sparse_price_flag                               AS IS_SPARSE_PRICE_FLAG,
    -- f.trend_source                                       AS MATERIAL_TREND_SOURCE,
    -- f.resolved_monthly_trend_pct                         AS EXPECTED_MONTHLY_TREND_PCT,
    -- f.avg_yoy_pct                                        AS AVG_YOY_PCT,

    -- Forecast output
    f.forecasted_contract_price                             AS FORECASTED_CONTRACT_PRICE,
    -- f.forecasted_wac_spread                              AS FORECASTED_WAC_SPREAD,

    -- Most recent actuals flags from base table
    COALESCE(la.wac_price_decrease_flag, 0)                 AS WAC_PRICE_DECREASE_FLAG
    -- la.wac_significant_decrease_flag                     AS WAC_SIGNIFICANT_DECREASE_FLAG,
    -- la.contract_price_drop_30pct_flag                    AS CONTRACT_PRICE_DROP_30PCT_FLAG,
    -- la.contract_price_inc_30pct_flag                     AS CONTRACT_PRICE_INC_30PCT_FLAG,

    -- Sparsity signals
    -- f.sap_months                                         AS SAP_MONTHS,
    -- f.recent_6m_months                                   AS RECENT_6M_MONTHS,
    -- f.latest_6_observed_months                           AS LATEST_6_OBSERVED_MONTHS,
    -- f.forecast_horizon_month_num                         AS FORECAST_HORIZON_MONTH_NUM

FROM uspd_analytics_den.analytics_gold.contract_price_bt_forecasted_v23 f
LEFT JOIN latest_actuals la ON f.groupby_key = la.groupby_key
CROSS JOIN ts
-- ── Run filter: add new runs here ────────────────────────────────────────────
WHERE f.run_id IN (
    'BT_2025_08',   -- consolidated view, 5-yr horizon (Aug 2025 → Aug 2030)
    'BT_2026_07'    -- Odyssey, 5-yr horizon (Jul 2026 → Jul 2031)
)
;