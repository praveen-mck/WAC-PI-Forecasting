-- =========================================================
-- STEP 3: TRAINING CLEAN v23
-- groupby_key replaces sap_cust_num_trim+mtrl_num partitions
--
-- Changes from previous:
--   Fix: contract_price_change_outlier_flag now distinguishes
--   genuine repricing events from transient spikes.
--   Previously, any MoM change > 50% was excluded as an outlier,
--   which caused legitimate contract reprice months (e.g. ELIQUIS
--   $90 → $450) to be filtered out, leaving the entire training
--   window at the stale pre-reprice price level.
--   Fix adds next_month_contract_price (LEAD) in the base CTE.
--   A large MoM change is now only flagged as an outlier if the
--   price REVERTS toward the prior level the following month
--   (next month within 20% of prev month = spike/noise).
--   If the price persists at the new level, or there is no next
--   month, the row is retained as a genuine reprice.
--   GX early-stage logic (>200% threshold, sap_months <= 3)
--   is unchanged.
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_training_clean_v23 AS
WITH base AS (
    SELECT
        b.*,

        ROW_NUMBER() OVER (
            PARTITION BY b.groupby_key
            ORDER BY b.cal_month_start_dt ASC
        ) AS series_month_index,

        COUNT(CASE WHEN b.exclude_from_training_flag = 0 THEN 1 END) OVER (
            PARTITION BY b.groupby_key
        ) AS series_valid_month_count,

        -- Forward-look to distinguish genuine reprice from transient spike.
        -- Used only in contract_price_change_outlier_flag below.
        LEAD(b.contract_price) OVER (
            PARTITION BY b.groupby_key
            ORDER BY b.cal_month_start_dt
        ) AS next_month_contract_price

    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
),

calc AS (
    SELECT
        b.*,
        b.sap_months / NULLIF(b.l2_months, 0) AS sap_to_l2_coverage_ratio,

        CASE
            -- GX early-stage: unchanged.
            -- High volatility expected in first 3 months; tight threshold retained.
            WHEN b.prev_month_contract_price IS NOT NULL
             AND b.prev_month_contract_price <> 0
             AND b.CUST_PROD_CATEGORY = 'GX'
             AND b.sap_months <= 3
             AND ABS(b.contract_price_mom_pct_change) > 2.00
            THEN 1

            -- All others: only flag as outlier if the large MoM change REVERTS.
            -- Reversion = next month snaps back within 20% of the pre-change price.
            -- If next month stays elevated, or there is no next month (series end),
            -- treat as a genuine reprice and retain the row for training.
            WHEN b.prev_month_contract_price IS NOT NULL
             AND b.prev_month_contract_price <> 0
             AND NOT (b.CUST_PROD_CATEGORY = 'GX' AND b.sap_months <= 3)
             AND ABS(b.contract_price_mom_pct_change) > 0.50
             AND b.next_month_contract_price IS NOT NULL
             AND ABS(b.next_month_contract_price
                     / NULLIF(b.prev_month_contract_price, 0) - 1) < 0.20
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