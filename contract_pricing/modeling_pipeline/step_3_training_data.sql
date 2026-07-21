-- =========================================================
-- STEP 3: TRAINING CLEAN  v18
--
-- Changes from v17:
--
--   1. CONDITIONAL OUTLIER THRESHOLD FOR NEW GENERICS
--      The v17 contract_price_change_outlier_flag excluded any month
--      with a MoM price change > 50%. For generic drugs (GX) in their
--      first 3 months of SAP history, this excluded legitimate large
--      price movements (100-800% repricing at network entry), causing
--      the anchor_contract_price in Step 4 to freeze at the pre-jump
--      price and never update. This is the root cause of the 100-800%
--      price drift seen in the Q4 anchor staleness analysis.
--
--      Fix: threshold is now conditional on acct_classification and
--      sap_months:
--        GX + sap_months <= 3  → 200% MoM threshold
--          (generic network-entry repricing is a real pricing event)
--        All other keys         → 50% MoM threshold (unchanged)
--
--      The 200% threshold was chosen to capture the observed drift
--      range (up to ~800%) while still excluding genuine single-month
--      data entry errors. Keys with >200% MoM change AND sap_months > 3
--      remain excluded under the original 50% rule.
--
--   Unchanged from v17:
--   - exclude_from_training_flag still takes precedence over outlier flag
--   - include_for_modeling_flag logic: exclude OR outlier → 0
--   - All MoM diagnostic columns retained
--   - sap_to_l2_coverage_ratio computation
--   - series_month_index and series_valid_month_count
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_training_clean_v18 AS
WITH ordered AS (
    SELECT
        b.*,

        LAG(b.contract_price) OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt
        ) AS prev_contract_price,

        LAG(b.wac_spread) OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt
        ) AS prev_wac_spread,

        ROW_NUMBER() OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
            ORDER BY b.cal_month_start_dt ASC
        ) AS series_month_index,

        COUNT(CASE WHEN b.exclude_from_training_flag = 0 THEN 1 END) OVER (
            PARTITION BY b.HYBRID_MODEL_KEY_3T, b.mtrl_num
        ) AS series_valid_month_count

    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v17 b
),

calc AS (
    SELECT
        o.*,

        CASE
            WHEN o.prev_contract_price IS NOT NULL
             AND o.prev_contract_price <> 0
            THEN (o.contract_price - o.prev_contract_price)
                 / o.prev_contract_price
        END                                             AS mom_contract_price_change_pct,

        CASE
            WHEN o.prev_wac_spread IS NOT NULL
            THEN o.wac_spread - o.prev_wac_spread
        END                                             AS mom_wac_spread_change_abs,

        -- =====================================================
        -- contract_price_change_outlier_flag  (v18 updated)
        --
        -- Threshold is conditional on segment and history depth:
        --
        --   GX + sap_months <= 3 → 200% MoM threshold
        --     Generic drugs in the first 3 months of SAP history
        --     routinely reprice 100-800% as they enter the network.
        --     Excluding these months freezes the anchor at the old
        --     price and prevents Step 4 from seeing the new level.
        --
        --   All other keys → 50% MoM threshold (v17 default)
        --     Preserves data-error filtering for established keys
        --     and non-generic segments.
        -- =====================================================
        CASE
            WHEN o.prev_contract_price IS NOT NULL
             AND o.prev_contract_price <> 0
             AND o.CUST_PROD_CATEGORY = 'GX'
             AND o.sap_months <= 3
             AND ABS(
                    (o.contract_price - o.prev_contract_price)
                    / o.prev_contract_price
                ) > 2.00                                -- 200% threshold for new generics
            THEN 1
            WHEN o.prev_contract_price IS NOT NULL
             AND o.prev_contract_price <> 0
             AND NOT (o.CUST_PROD_CATEGORY = 'GX' AND o.sap_months <= 3)
             AND ABS(
                    (o.contract_price - o.prev_contract_price)
                    / o.prev_contract_price
                ) > 0.50                                -- 50% threshold for all others
            THEN 1
            ELSE 0
        END                                             AS contract_price_change_outlier_flag,

        o.sap_months / NULLIF(o.l2_months, 0)          AS sap_to_l2_coverage_ratio

    FROM ordered o
)

SELECT
    c.*,

    CASE
        WHEN c.exclude_from_training_flag = 1          THEN 0
        WHEN c.contract_price_change_outlier_flag = 1  THEN 0
        ELSE 1
    END                                                 AS include_for_modeling_flag

FROM calc c
;