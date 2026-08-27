-- =========================================================
-- STEP 7b (LIVE): FORECAST OUTPUT FORMATTED v1
-- Final consumption schema with load metadata and
-- most recent actuals flags joined from base table.
-- Live version uses contract_price_live_forecasted_v23.
--
-- Fix: FORECAST_YEAR_NUM corrected from
--      FLOOR(MONTHS_BETWEEN(...)/12) + 12  →  YEAR(f.forecast_month).
--      Prior formula always added 12 and used MONTHS_BETWEEN which
--      can return fractional values. YEAR() is exact and matches
--      the BT output table definition.
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_live_forecast_output_monthly_v1 AS

WITH latest_actuals AS (
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
    CURRENT_TIMESTAMP()                                 AS LOAD_TS,
    TO_DATE(CURRENT_TIMESTAMP())                        AS LOAD_DATE,
    DATE_FORMAT(CURRENT_TIMESTAMP(), 'HH:mm')           AS LOAD_TIME,
    DATE_FORMAT(CURRENT_TIMESTAMP(), 'yyyy-MM')         AS LOAD_YEAR_MONTH,

    -- Series key
    f.groupby_key,

    -- Forecast origin / horizon
    DATE_FORMAT(f.jump_off_month, 'yyyy-MM')            AS FCST_ORIGIN_YEAR_MONTH,
    f.forecast_horizon_month_num                        AS FORECAST_HORIZON_MONTH_NUM,
    f.forecast_year_month                               AS FORECAST_CAL_YEAR_MONTH,
    -- Fix: YEAR(forecast_month) replaces FLOOR(MONTHS_BETWEEN(...)/12)+12.
    -- Prior formula always added 12 and used MONTHS_BETWEEN which
    -- can return fractional values causing incorrect year assignment.
    YEAR(f.forecast_month)                              AS FORECAST_YEAR_NUM,
    -- McKesson FY starts April 1.
    -- FY = calendar year + 1 for months Apr–Dec, calendar year for Jan–Mar.
    -- Fiscal month: Apr=01, May=02, Jun=03, Jul=04, Aug=05, Sep=06,
    --               Oct=07, Nov=08, Dec=09, Jan=10, Feb=11, Mar=12
    CONCAT(
        'FY',
        CASE WHEN MONTH(f.forecast_month) >= 4
             THEN YEAR(f.forecast_month) + 1
             ELSE YEAR(f.forecast_month)
        END,
        '-',
        LPAD(CASE WHEN MONTH(f.forecast_month) >= 4
                  THEN MONTH(f.forecast_month) - 3
                  ELSE MONTH(f.forecast_month) + 9
             END, 2, '0')
    )                                                   AS FORECAST_FISCAL_YEAR_MONTH,

    -- Product identifiers
    f.cust_prod_category                                AS SLS_CTGRY_PRC_PROD_GRP,
    f.ndc_num                                           AS NDC_NUM,
    f.mtrl_num                                          AS MTRL_NUM,

    -- Customer identifiers
    f.common_grp_id                                     AS COMMON_GRP_ID,
    f.common_grp_desc                                   AS COMMON_GRP_NAME,
    -- f.subset_l2_id_resolved                          AS SUBSET_L2_ID,
    f.sap_cust_num_trim                                 AS SAP_CUST_NUM,
    f.cust_segment                                      AS CUST_SEGMENT,
    f.acct_classification                               AS ACCT_CLASSIFICATION,
    f.national_grp_id                                   AS NATIONAL_GRP_ID,
    -- f.national_grp_desc                              AS NATIONAL_GRP_DESC,

    -- Manufacturer / product descriptors
    f.manufacturer_id                                   AS MANUFACTURER_ID,
    -- f.mtrl_nme_nvgton                                AS MTRL_NME_NVGTON,
    -- f.product_family                                 AS PRODUCT_FAMILY,
    -- f.therapeutic_class                              AS THERAPEUTIC_CLASS,
    -- f.final_product_group                            AS FINAL_PRODUCT_GROUP,

    -- Anchor / assumptions context (commented out to match v1 output schema)
    -- f.anchor_month                                   AS ANCHOR_MONTH,
    -- f.anchor_contract_price                          AS ANCHOR_CONTRACT_PRICE,
    -- f.anchor_wac_spread                              AS ANCHOR_WAC_SPREAD,
    -- f.forecast_start_contract_price                  AS FORECAST_START_CONTRACT_PRICE,
    -- f.forecast_start_price_source                    AS FORECAST_START_PRICE_SOURCE,
    -- f.sparse_price_confidence                        AS SPARSE_PRICE_CONFIDENCE,
    -- f.is_sparse_price_flag                           AS IS_SPARSE_PRICE_FLAG,
    -- f.trend_source                                   AS MATERIAL_TREND_SOURCE,
    -- f.resolved_monthly_trend_pct                     AS EXPECTED_MONTHLY_TREND_PCT,

    -- Forecast output
    f.forecasted_contract_price                         AS FORECASTED_CONTRACT_PRICE,
    -- f.implied_forecast_wac_spread                    AS FORECASTED_WAC_SPREAD,

    -- Most recent actuals flags from base table
    COALESCE(la.wac_price_decrease_flag, 0)             AS WAC_PRICE_DECREASE_FLAG
    -- la.wac_significant_decrease_flag                 AS WAC_SIGNIFICANT_DECREASE_FLAG,
    -- la.contract_price_drop_30pct_flag                AS CONTRACT_PRICE_DROP_30PCT_FLAG,
    -- la.contract_price_inc_30pct_flag                 AS CONTRACT_PRICE_INC_30PCT_FLAG

    -- Sparsity signals (commented out to match v1 output schema)
    -- f.recent_6m_months                               AS RECENT_6M_MONTHS,
    -- f.latest_6_observed_months                       AS LATEST_6_OBSERVED_MONTHS,
    -- f.forecast_horizon_month_num                     AS FORECAST_HORIZON_MONTH_NUM

FROM uspd_analytics_den.analytics_gold.contract_price_live_forecasted_v23 f
LEFT JOIN latest_actuals la ON f.groupby_key = la.groupby_key
;