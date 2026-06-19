-- =========================================================
-- STEP 3: TRAINING CLEAN
-- - Keeps row-level monthly series data
-- - Adds MoM diagnostics
-- - Uses existing base-table flags plus simple change outlier filter
-- - Keeps rows, but marks include_for_modeling_flag
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_training_clean_v2 AS
WITH ordered AS (
    SELECT
        b.*,

        LAG(b.contract_price) OVER (
            PARTITION BY b.customer_group_key_id, b.mtrl_num
            ORDER BY b.cal_month_start_dt
        ) AS prev_contract_price,

        LAG(b.wac_spread) OVER (
            PARTITION BY b.customer_group_key_id, b.mtrl_num
            ORDER BY b.cal_month_start_dt
        ) AS prev_wac_spread

    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v2 b
),

calc AS (
    SELECT
        o.*,

        CASE
            WHEN o.prev_contract_price IS NOT NULL AND o.prev_contract_price <> 0
            THEN (o.contract_price - o.prev_contract_price) / o.prev_contract_price
        END AS mom_contract_price_change_pct,

        CASE
            WHEN o.prev_wac_spread IS NOT NULL
            THEN o.wac_spread - o.prev_wac_spread
        END AS mom_wac_spread_change_abs,

        CASE
            WHEN o.prev_contract_price IS NOT NULL
             AND o.prev_contract_price <> 0
             AND ABS((o.contract_price - o.prev_contract_price) / o.prev_contract_price) > 0.50
            THEN 1 ELSE 0
        END AS contract_price_change_outlier_flag

    FROM ordered o
)

SELECT
    c.*,

    CASE
        WHEN c.exclude_from_training_flag = 1 THEN 0
        WHEN c.contract_price_change_outlier_flag = 1 THEN 0
        ELSE 1
    END AS include_for_modeling_flag

FROM calc c
;
