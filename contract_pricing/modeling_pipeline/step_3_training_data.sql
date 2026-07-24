-- =========================================================
-- STEP 3: TRAINING CLEAN v19
--
-- Changes from v18:
--   - Source updated to contract_price_modeling_base_v19
--   - ordered CTE dropped entirely. MoM columns now pulled
--     directly from base table where they are pre-computed:
--       prev_month_contract_price  (was: LAG(contract_price))
--       prev_month_wac_weighted    (was: LAG(wac_spread) — note:
--         prev_wac_spread was used only to compute abs change)
--       contract_price_mom_pct_change (was: recomputed inline)
--       wac_spread_mom_abs_change  (new in v19 base; replaces
--         the mom_wac_spread_change_abs recompute here)
--   - series_month_index and series_valid_month_count window
--     functions retained but now applied directly over base
--     without the ordered CTE wrapper
--   - contract_price_change_outlier_flag logic unchanged
--     (GX + sap_months <= 3 → 200% threshold; all others 50%)
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_training_clean_v19 AS
WITH base AS (
    SELECT
        b.*,

        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt ASC
        ) AS series_month_index,

        COUNT(CASE WHEN b.exclude_from_training_flag = 0 THEN 1 END) OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
        ) AS series_valid_month_count

    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v19 b
),

calc AS (
    SELECT
        b.*,

        -- MoM columns (prev_month_contract_price, prev_month_wac_weighted,
        -- contract_price_mom_pct_change, wac_spread_mom_abs_change) are
        -- already included via b.* from the base table. No recompute needed.

        b.sap_months / NULLIF(b.l2_months, 0) AS sap_to_l2_coverage_ratio,

        -- =====================================================
        -- contract_price_change_outlier_flag
        --
        -- GX + sap_months <= 3 → 200% MoM threshold
        --   Generic network-entry repricing (100-800%) is a
        --   real pricing event; excluding freezes the anchor.
        --
        -- All other keys → 50% MoM threshold
        -- =====================================================
        CASE
            WHEN b.prev_month_contract_price IS NOT NULL
             AND b.prev_month_contract_price <> 0
             AND b.CUST_PROD_CATEGORY = 'GX'
             AND b.sap_months <= 3
             AND ABS(b.contract_price_mom_pct_change) > 2.00
            THEN 1
            WHEN b.prev_month_contract_price IS NOT NULL
             AND b.prev_month_contract_price <> 0
             AND NOT (b.CUST_PROD_CATEGORY = 'GX' AND b.sap_months <= 3)
             AND ABS(b.contract_price_mom_pct_change) > 0.50
            THEN 1
            ELSE 0
        END AS contract_price_change_outlier_flag

    FROM base b
)

SELECT
    c.*,

    CASE
        WHEN c.exclude_from_training_flag = 1         THEN 0
        WHEN c.contract_price_change_outlier_flag = 1 THEN 0
        ELSE 1
    END AS include_for_modeling_flag

FROM calc c
;