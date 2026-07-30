
-- =========================================================
-- STEP 6: FUTURE MONTHS v21
-- groupby_key carried through; fixed jump-off parametized
-- =========================================================
 
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_future_months_v21 AS
WITH params AS (
    SELECT TO_DATE('2025-08-01') AS jump_off_dt
),
 
base AS (
    SELECT groupby_key, sap_cust_num_trim, mtrl_num, anchor_month
    FROM uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v21
),
 
expanded AS (
    SELECT
        b.groupby_key, b.sap_cust_num_trim, b.mtrl_num, b.anchor_month,
        p.jump_off_dt,
        EXPLODE(SEQUENCE(
            p.jump_off_dt,
            ADD_MONTHS(p.jump_off_dt, 59),
            INTERVAL 1 MONTH
        )) AS forecast_month
    FROM base b
    CROSS JOIN params p
)
 
SELECT
    e.groupby_key,
    e.sap_cust_num_trim,
    e.mtrl_num,
    e.anchor_month,
    e.jump_off_dt,
    e.forecast_month,
    CAST(months_between(e.forecast_month, e.anchor_month) AS INT)
                                                        AS forecast_horizon_month_num,
    DATE_FORMAT(e.forecast_month, 'yyyy-MM')            AS forecast_cal_year_month,
    DATE_FORMAT(ADD_MONTHS(e.forecast_month, 9), 'yyyy-MM')
                                                        AS forecast_fiscal_year_month,
    FLOOR(months_between(e.forecast_month, e.jump_off_dt) / 12.0) + 1
    AS forecast_year_num
FROM expanded e
;
