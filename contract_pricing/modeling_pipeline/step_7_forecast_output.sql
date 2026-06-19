-- =========================================================
-- STEP 6: FUTURE MONTHS
-- - Generates 60 future monthly periods after each series anchor month
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_future_months_v2 AS
WITH base AS (
    SELECT
        customer_group_key_id,
        mtrl_num,
        anchor_month
    FROM uspd_analytics_den.analytics_gold.contract_price_resolved_assumptions_v2
),

expanded AS (
    SELECT
        b.customer_group_key_id,
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
    e.customer_group_key_id,
    e.mtrl_num,
    e.anchor_month,
    e.forecast_month,
    CAST(months_between(e.forecast_month, e.anchor_month) AS INT) AS forecast_horizon_month_num,
    DATE_FORMAT(e.forecast_month, 'yyyy-MM') AS forecast_year_month
FROM expanded e
;
