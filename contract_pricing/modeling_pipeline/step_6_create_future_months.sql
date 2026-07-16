-- =========================================================
-- STEP 6: FUTURE MONTHS
-- - Generates 60 future monthly periods after each series anchor month
-- - Keyed on HYBRID_MODEL_KEY_3T + mtrl_num
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_future_months_v16 AS
WITH base AS (
    SELECT
        HYBRID_MODEL_KEY_3T,
        mtrl_num,
        anchor_month
    FROM uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v16
),

expanded AS (
    SELECT
        b.HYBRID_MODEL_KEY_3T,
        b.mtrl_num,
        b.anchor_month,
        EXPLODE(SEQUENCE(
            ADD_MONTHS(b.anchor_month, 1),
            ADD_MONTHS(b.anchor_month, 60),
            INTERVAL 1 MONTH
        )) AS forecast_month
    FROM base b
)

SELECT
    e.HYBRID_MODEL_KEY_3T,
    e.mtrl_num,
    e.anchor_month,
    e.forecast_month,
    CAST(months_between(e.forecast_month, e.anchor_month) AS INT)
                                                        AS forecast_horizon_month_num,
    DATE_FORMAT(e.forecast_month, 'yyyy-MM')            AS forecast_year_month
FROM expanded e
;


-- =========================================================
-- STEP 7: FORECAST
-- - Applies forecast_start_contract_price + 0 trend across
--   all 60 future months
-- - Joins material assumptions for full descriptor context
-- - forecast_start_contract_price is the v16 price anchor:
--     prior 12m avg (>= 6 months) -> latest observed avg (>= 6) -> last price
-- =========================================================

