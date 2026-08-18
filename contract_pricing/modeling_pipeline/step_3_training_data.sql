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
--
-- Fix 9 (new) — next_month_contract_price now reads the next
--   non-excluded row's contract price rather than the raw next
--   row. A spike in month T followed by an excluded row in T+1
--   (e.g. zombie WAC-ceiling row) previously caused the reversion
--   check to fire on a meaningless WAC price, incorrectly flagging
--   month T as an outlier when it was a genuine reprice.
--   Fix uses next_valid_contract_price via LEAD IGNORE NULLS over
--   contract_price masked to NULL for excluded rows.
--
-- Fix 10 (noted, not changed) — GX outlier threshold asymmetry
--   past month 3: GX keys past sap_months=3 fall through to the
--   general >50% rule identically to BX/APOLLO. Confirmed as
--   intended — no GX-specific wider window needed beyond month 3.
--
-- Fix 11 (noted) — series_valid_month_count reflects
--   exclude_from_training_flag only (from modeling_base), not
--   the additional contract_price_change_outlier_flag exclusions
--   added in this step. Downstream consumers of
--   series_valid_month_count should use include_for_modeling_flag
--   counts instead. Column retained as-is for backward compat.
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
        -- Note (Fix 11): series_valid_month_count counts rows where
        -- exclude_from_training_flag = 0 (from modeling_base only).
        -- It does NOT account for contract_price_change_outlier_flag
        -- exclusions added below. Downstream steps should use
        -- include_for_modeling_flag = 1 counts for true valid month counts.

        -- Fix 9: next_valid_contract_price uses LEAD IGNORE NULLS
        -- over contract_price masked to NULL for excluded rows.
        -- Prevents the reversion check from firing on zombie WAC-ceiling
        -- rows or other excluded months that immediately follow a large
        -- MoM change, which would incorrectly flag genuine reprices as outliers.
        LEAD(
            CASE WHEN b.exclude_from_training_flag = 0 THEN b.contract_price END
        ) IGNORE NULLS OVER (
            PARTITION BY b.groupby_key
            ORDER BY b.cal_month_start_dt
        ) AS next_valid_contract_price

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

            -- All others: only flag as outlier if the large MoM change REVERTS
            -- to within 20% of the pre-change price in the next VALID month.
            -- Fix 9: uses next_valid_contract_price (non-excluded rows only)
            -- instead of raw next row, preventing zombie/excluded rows from
            -- triggering false reversion signals.
            WHEN b.prev_month_contract_price IS NOT NULL
             AND b.prev_month_contract_price <> 0
             AND NOT (b.CUST_PROD_CATEGORY = 'GX' AND b.sap_months <= 3)
             AND ABS(b.contract_price_mom_pct_change) > 0.50
             AND b.next_valid_contract_price IS NOT NULL
             AND ABS(b.next_valid_contract_price
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


-- =========================================================
-- STEP 3 QA QUERIES
-- =========================================================

-- Q_S3_1: Outlier flag distribution by category
-- Verify that genuine reprices (e.g. ELIQUIS, XARELTO) are
-- NOT flagged as outliers. Check that outlier rates are low
-- for APOLLO and BX branded drugs.
SELECT
    cust_prod_category,
    COUNT(*) AS total_rows,
    SUM(contract_price_change_outlier_flag)                 AS outlier_flagged,
    SUM(include_for_modeling_flag)                          AS included_for_modeling,
    ROUND(SUM(contract_price_change_outlier_flag)
          / NULLIF(COUNT(*), 0) * 100, 2)                   AS outlier_pct
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
GROUP BY cust_prod_category
ORDER BY outlier_pct DESC;

-- Q_S3_2: Confirm Fix 9 — check rows where next_valid_contract_price
-- differs materially from raw next row contract_price (indicates zombie
-- rows were correctly skipped by LEAD IGNORE NULLS).
-- Rows returned here are where Fix 9 changed the reversion signal.
SELECT
    groupby_key,
    cal_month_start_dt,
    contract_price,
    prev_month_contract_price,
    next_valid_contract_price,
    contract_price_mom_pct_change,
    contract_price_change_outlier_flag,
    exclude_from_training_flag
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
WHERE ABS(contract_price_mom_pct_change) > 0.50
  AND next_valid_contract_price IS NOT NULL
  AND exclude_from_training_flag = 0
ORDER BY ABS(contract_price_mom_pct_change) DESC
LIMIT 100;

-- Q_S3_3: Spot-check known genuine reprices are NOT flagged
-- Replace brand_name values with known high-value repriced drugs
-- in your environment (e.g. ELIQUIS, XARELTO, ENBREL).
SELECT
    groupby_key,
    brand_name,
    cal_month_start_dt,
    contract_price,
    prev_month_contract_price,
    contract_price_mom_pct_change,
    contract_price_change_outlier_flag,
    include_for_modeling_flag
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
WHERE brand_name IN ('ELIQUIS','XARELTO','ENBREL','JANUVIA','HUMIRA')
  AND ABS(contract_price_mom_pct_change) > 0.20
ORDER BY brand_name, cal_month_start_dt;

-- Q_S3_4: series_valid_month_count vs actual include_for_modeling_flag
-- counts — documents the Fix 11 discrepancy for downstream awareness.
SELECT
    groupby_key,
    MAX(series_valid_month_count)                           AS series_valid_month_count,
    SUM(include_for_modeling_flag)                          AS actual_modeled_months,
    MAX(series_valid_month_count)
        - SUM(include_for_modeling_flag)                    AS outlier_excluded_months
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
GROUP BY groupby_key
HAVING MAX(series_valid_month_count) != SUM(include_for_modeling_flag)
ORDER BY outlier_excluded_months DESC
LIMIT 50;

-- Q_S3_5: GX early-stage outlier rate — confirm sap_months <= 3
-- threshold is behaving as expected.
SELECT
    sap_months,
    COUNT(*) AS rows,
    SUM(contract_price_change_outlier_flag) AS outlier_count
FROM uspd_analytics_den.analytics_gold.contract_price_training_clean_v23
WHERE cust_prod_category = 'GX'
  AND prev_month_contract_price IS NOT NULL
GROUP BY sap_months
ORDER BY sap_months;