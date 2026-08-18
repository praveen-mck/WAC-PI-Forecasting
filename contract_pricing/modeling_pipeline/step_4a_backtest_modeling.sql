-- =========================================================
-- STEP 4 (LIVE): CONTRACT PRICE MATERIAL LIVE ASSUMPTIONS v23
--
-- Live forecasting version of Step 4.
-- Produces one row per groupby_key (no run_id).
-- Uses full training history — no point-in-time caps.
--
-- Jump-off date: dynamically derived as the latest available
-- cal_month_start_dt in contract_price_modeling_base_v23.
-- To override with a fixed date, replace the jump_off subquery
-- with: SELECT DATE '2025-06-01' AS jump_off_month
--
-- Key differences from BT version:
--   No run_id — one row per groupby_key
--   No history_end_dt cap — full training history used
--   No jump_off_month cap on post_anchor signals
--   post_anchor_wac/cp use all months after anchor
--   Feeds: contract_price_live_resolved_assumptions_v23
--
-- v23 changes (see full changelog in prior versions):
--   (a) PF/MFR fallback trend cap reverted to ±2% outer cap only.
--   (b) BX sparse fallback negative-only restriction.
--   (c) APOLLO + BX typical_increase_month detection.
--   (d) APOLLO + BX step-up / step-down history logic.
--
-- Fixes applied in this file vs v23d source:
--
--   Fix 12 (Critical) — Nested window functions in step_history_mom.
--     LAST_VALUE IGNORE NULLS referenced LAG() inside its argument,
--     which is invalid in Snowflake (window inside window argument).
--     Split into two CTEs:
--       step_history_mom_raw — computes LAG-based MoM changes and
--         recent_wac_mom_change_if_in_window per row.
--       step_history_mom     — applies LAST_VALUE IGNORE NULLS over
--         the already-computed cp_mom_pct_change from _raw.
--     apollo_mom and step_history_mom_raw also merged into a single
--     training_clean scan (Fix 13b / performance).
--
--   Fix 13 (Medium) — Dead BX sparse fallback block removed from
--     ELSE ±2% branch of expected_monthly_trend_pct. BX non-340B
--     keys are fully captured by the ±15% WHEN block and can never
--     reach the ELSE branch. Removed to eliminate dead code and
--     prevent future confusion.
--
--   Fix 14 (Low) — acct_classification added to final SELECT.
--     Was computed in guardrails CTE but never forwarded to output.
--
--   Fix 15 (Low) — trend_cap_applied diagnostic column added to
--     final SELECT. Indicates which outer cap bound was applied
--     per key, enabling QA of cap-lifted segments.
--
--   Cap lift — expected_monthly_trend_pct outer cap restructured:
--     APOLLO        ±15% (was ±2%)
--     MPB Specialty ±15% (was ±2%)
--     BX non-340B   ±15% (was ±2%)
--     DROP SHIP non-340B ±10% (was ±2%)
--     All others    ±2%  (unchanged)
--     Diagnostic data showed 94-99% pct_clipped_high_confidence
--     for BX/MPB Specialty clipped buckets. GX, BIOSIMS, OTC, VAX
--     retain ±2% — outlier avg_raw_yoy_pct values indicate cap is
--     doing real noise suppression work for these segments.
--
-- Feeds: contract_price_bt_resolved_assumptions_v23
--
-- Output columns (in order):
--   run_id, groupby_key, cust_prod_category, acct_classification,
--   anchor_month, anchor_contract_price, anchor_wac_spread,
--   sap_months, recent_6m_months, prior_6m_months,
--   recent_6m_avg_contract_price, prior_6m_avg_contract_price,
--   recent_6m_avg_wac_spread, latest_6_observed_months,
--   latest_6_observed_avg_contract_price, latest_6_observed_avg_wac_spread,
--   post_anchor_avg_wac_spread, post_anchor_months,
--   post_anchor_avg_contract_price, post_anchor_cp_months,
--   yoy_pairs_used, avg_yoy_pct, directional_consistency,
--   raw_regression_trend_pct, pf_yoy_pairs_used, pf_avg_yoy_pct,
--   mfr_yoy_pairs_used, mfr_avg_yoy_pct, sign_only_eligible,
--   g5_recent_price_not_falling, typical_increase_month,
--   step_up_count, avg_step_up_pct, step_down_count,
--   avg_step_down_pct, last_step_direction, recent_wac_avg_mom_change,
--   forecast_start_contract_price, forecast_start_wac_spread,
--   forecast_start_price_source, expected_monthly_trend_pct,
--   assigned_trend_method, trend_cap_applied,
--   sparse_price_confidence, is_sparse_price_flag
--
-- QA notes (see bottom of file):
--   Q1 — Keys switching from NO_TREND to fallback method.
--   Q2 — Bias check pre/post fallback.
--   Q3 — No key-level trend override.
--   Q4 — PF/MFR avg_yoy_pct variance vs key-level.
--   Q5 — Step history coverage by category.
--   Q6 — Step magnitude sanity check.
--   Q7 — Cap lift validation: pct of keys at cap boundary by segment.
-- =========================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23 AS
WITH -- ── jump_off_month: latest available month in modeling_base ───────────────
-- Override: replace with SELECT DATE '2025-06-01' AS jump_off_month
-- to use a fixed date instead of dynamic latest month.
jump_off AS (
    SELECT MAX(cal_month_start_dt) AS jump_off_month
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
    WHERE exclude_from_training_flag = 0
),
-- ── all_keys: all active groupby_keys with at least 1 training month ──────
all_keys AS (
    SELECT DISTINCT groupby_key
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
    WHERE exclude_from_training_flag = 0
),
-- ── sap_coverage: full history month count (no cap) ───────────────────────
sap_coverage AS (
    SELECT
        b.groupby_key,
        COUNT(DISTINCT b.cal_month_start_dt)    AS sap_months_bt
    FROM all_keys a
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON a.groupby_key = b.groupby_key
     AND b.exclude_from_training_flag = 0
    GROUP BY b.groupby_key
),
recent_6m AS (
    SELECT
        a.groupby_key,
        la.anchor_month,
        COUNT(DISTINCT CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(la.anchor_month, -6)
            THEN b.cal_month_start_dt END)                  AS recent_6m_months,
        COUNT(DISTINCT CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(la.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(la.anchor_month, -6)
            THEN b.cal_month_start_dt END)                  AS prior_6m_months,
        NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(la.anchor_month, -6)
            THEN b.total_net_cos END), 0)
        / NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(la.anchor_month, -6)
            THEN b.total_sls_qty END), 0)                   AS recent_6m_avg_contract_price,
        NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(la.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(la.anchor_month, -6)
            THEN b.total_net_cos END), 0)
        / NULLIF(SUM(CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(la.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(la.anchor_month, -6)
            THEN b.total_sls_qty END), 0)                   AS prior_6m_avg_contract_price,
        AVG(CASE
            WHEN b.cal_month_start_dt > ADD_MONTHS(la.anchor_month, -6)
            THEN b.wac_spread END)                          AS recent_6m_avg_wac_spread,
        AVG(CASE
            WHEN b.cal_month_start_dt >  ADD_MONTHS(la.anchor_month, -12)
             AND b.cal_month_start_dt <= ADD_MONTHS(la.anchor_month, -6)
            THEN b.wac_spread END)                          AS prior_6m_avg_wac_spread
    FROM all_keys a
    JOIN uspd_analytics_den.analytics_gold.contract_price_last_actual_v23 la
      ON a.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON a.groupby_key = b.groupby_key
     AND b.exclude_from_training_flag = 0
    GROUP BY a.groupby_key, la.anchor_month
),
post_anchor_wac AS (
    SELECT
        b.groupby_key,
        AVG(b.wac_spread)                               AS post_anchor_avg_wac_spread,
        COUNT(DISTINCT b.cal_month_start_dt)            AS post_anchor_months
    FROM all_keys a
    JOIN uspd_analytics_den.analytics_gold.contract_price_last_actual_v23 la
      ON a.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON a.groupby_key = b.groupby_key
     AND b.cal_month_start_dt >  la.anchor_month
     AND b.exclude_from_actuals_flag = 0
     AND b.wac_spread IS NOT NULL
    GROUP BY b.groupby_key
),
post_anchor_cp AS (
    SELECT
        b.groupby_key,
        NULLIF(SUM(b.total_net_cos), 0)
            / NULLIF(SUM(b.total_sls_qty), 0)           AS post_anchor_avg_contract_price,
        COUNT(DISTINCT b.cal_month_start_dt)            AS post_anchor_cp_months
    FROM all_keys a
    JOIN uspd_analytics_den.analytics_gold.contract_price_last_actual_v23 la
      ON a.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON a.groupby_key = b.groupby_key
     AND b.cal_month_start_dt >  la.anchor_month
     AND b.exclude_from_actuals_flag = 0
     AND b.total_net_cos IS NOT NULL
     AND b.total_sls_qty IS NOT NULL
    GROUP BY b.groupby_key
),
yearly_price AS (
    SELECT
        b.groupby_key,
        CEIL((DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) + 1) / 12.0) AS yr_bucket,
        NULLIF(SUM(b.total_net_cos), 0) / NULLIF(SUM(b.total_sls_qty), 0)          AS yr_price
    FROM all_keys a
    JOIN uspd_analytics_den.analytics_gold.contract_price_last_actual_v23 la
      ON a.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON a.groupby_key = b.groupby_key
     AND b.exclude_from_training_flag = 0
     AND DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) BETWEEN 0 AND 47
    GROUP BY b.groupby_key,
             CEIL((DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) + 1) / 12.0)
),
yearly_yoy AS (
    SELECT
        y_curr.groupby_key,
        (y_curr.yr_price / NULLIF(y_prev.yr_price, 0)) - 1     AS yoy_pct,
        CASE
            WHEN (y_curr.yr_price / NULLIF(y_prev.yr_price, 0)) - 1 > 0
            THEN 1 ELSE 0
        END                                                     AS is_positive
    FROM yearly_price y_curr
    JOIN yearly_price y_prev
      ON y_curr.groupby_key  = y_prev.groupby_key
     AND y_curr.yr_bucket    = y_prev.yr_bucket - 1
    WHERE y_curr.yr_price IS NOT NULL
      AND y_prev.yr_price  IS NOT NULL
),
trend_direction AS (
    SELECT
        groupby_key,
        -- yoy_pairs_used counts ALL pairs including extreme ones,
        -- so eligibility thresholds (>= 1, >= 2) are unaffected.
        COUNT(*)                                        AS yoy_pairs_used,
        -- YOY pair sanity filter: exclude pairs where |yoy_pct| > 5.0 (500%)
        -- before averaging. These are almost entirely tiny-price 340B APOLLO
        -- keys where price moved from near-zero to thousands in one year
        -- (e.g. $0.01 → $1.00 = 9,900% YOY), contaminating avg_yoy_pct
        -- and producing nonsensical trend rates even after the ±15% outer cap.
        -- Excluded pairs still count toward yoy_pairs_used and is_positive
        -- for directional_consistency so eligibility is not affected.
        -- The ±15% cap remains the final safety net; this filter removes
        -- the signal distortion before it reaches the average.
        AVG(CASE WHEN ABS(yoy_pct) <= 5.0 THEN yoy_pct END)
                                                        AS avg_yoy_pct,
        AVG(CAST(is_positive AS FLOAT))                 AS pct_positive_pairs,
        GREATEST(
            AVG(CAST(is_positive AS FLOAT)),
            1 - AVG(CAST(is_positive AS FLOAT))
        )                                               AS directional_consistency
    FROM yearly_yoy
    GROUP BY groupby_key
),
quarterly_price AS (
    SELECT
        b.groupby_key,
        CEIL((DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) + 1) / 3.0) AS qtr_bucket,
        NULLIF(SUM(b.total_net_cos), 0) / NULLIF(SUM(b.total_sls_qty), 0)         AS qtr_price
    FROM all_keys a
    JOIN uspd_analytics_den.analytics_gold.contract_price_last_actual_v23 la
      ON a.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON a.groupby_key = b.groupby_key
     AND b.exclude_from_training_flag = 0
     AND DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) BETWEEN 0 AND 23
    GROUP BY b.groupby_key,
             CEIL((DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) + 1) / 3.0)
),
quarterly_with_x AS (
    SELECT
        groupby_key,
        qtr_price,
        MAX(qtr_bucket) OVER (PARTITION BY groupby_key) - qtr_bucket AS x
    FROM quarterly_price
    WHERE qtr_price IS NOT NULL
),
trend_regression AS (
    SELECT
        groupby_key,
        COUNT(*)                                            AS quarters_used,
        (COUNT(*) * SUM(x * qtr_price) - SUM(x) * SUM(qtr_price))
        / NULLIF(
            COUNT(*) * SUM(x * x) - SUM(x) * SUM(x),
          0)                                               AS ols_slope,
        AVG(qtr_price)                                     AS avg_price_ref
    FROM quarterly_with_x
    GROUP BY groupby_key
),
pf_lookup AS (
    SELECT
        b.groupby_key,
        MAX(b.product_family)           AS product_family,
        MAX(b.manufacturer_id)          AS manufacturer_id,
        MAX(b.cust_prod_category)       AS cust_prod_category,
        MAX(b.acct_classification)      AS acct_classification
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
    GROUP BY b.groupby_key
),
pf_trend AS (
    SELECT
        pf.product_family,
        COUNT(*)                                        AS pf_yoy_pairs_used,
        AVG(yy.yoy_pct)                                 AS pf_avg_yoy_pct
    FROM yearly_yoy yy
    JOIN pf_lookup pf ON yy.groupby_key = pf.groupby_key
    WHERE pf.product_family IS NOT NULL
    GROUP BY pf.product_family
),
mfr_trend AS (
    SELECT
        pf.manufacturer_id,
        COUNT(*)                                        AS mfr_yoy_pairs_used,
        AVG(yy.yoy_pct)                                 AS mfr_avg_yoy_pct
    FROM yearly_yoy yy
    JOIN pf_lookup pf ON yy.groupby_key = pf.groupby_key
    WHERE pf.manufacturer_id IS NOT NULL
    GROUP BY pf.manufacturer_id
),
-- ── Fix 12 + Fix 13b: merged apollo_mom and step_history_mom_raw ──────────
-- Single scan of contract_price_training_clean_v23 for all APOLLO, BX,
-- GLP-1, MPB Specialty, MPB Plasma keys. Replaces the two separate CTEs
-- (apollo_mom and step_history_mom) that previously both joined training_clean.
-- LAG computations for cp_mom and wac_mom done here (step 1 of Fix 12 split).
combined_mom_raw AS (
    SELECT
        t.groupby_key,
        t.cal_month_start_dt,
        pf.cust_prod_category,
        MONTH(t.cal_month_start_dt)                     AS price_month,
        t.contract_price
            / NULLIF(LAG(t.contract_price) OVER (
                PARTITION BY t.groupby_key
                ORDER BY t.cal_month_start_dt
            ), 0) - 1                                   AS cp_mom_pct_change,
        t.wac
            / NULLIF(LAG(t.wac) OVER (
                PARTITION BY t.groupby_key
                ORDER BY t.cal_month_start_dt
            ), 0) - 1                                   AS wac_mom_pct_change,
        -- Recent WAC MoM: last 6 months before jump_off
        CASE
            WHEN t.cal_month_start_dt > ADD_MONTHS(jo.jump_off_month, -6)
            THEN t.wac / NULLIF(LAG(t.wac) OVER (
                     PARTITION BY t.groupby_key
                     ORDER BY t.cal_month_start_dt
                 ), 0) - 1
        END                                             AS recent_wac_mom_change_if_in_window
    FROM all_keys a
    CROSS JOIN jump_off jo
    JOIN uspd_analytics_den.analytics_gold.contract_price_training_clean_v23 t
      ON a.groupby_key = t.groupby_key
    JOIN pf_lookup pf
      ON t.groupby_key = pf.groupby_key
    WHERE pf.cust_prod_category IN ('APOLLO', 'BX', 'GLP-1', 'MPB Specialty', 'MPB Plasma')
),
-- ── Fix 12 step 2: resolve last_step_direction without LAST_VALUE IGNORE NULLS ─
-- LAST_VALUE IGNORE NULLS is not supported in all Databricks runtimes.
-- Workaround: two-step approach using numeric epoch sort.
--
-- Step 1 (combined_mom_raw already done): cp_mom_pct_change is available per row.
-- Step 2 here: find the epoch (unix date) of the most recent significant step
--   using MAX(CASE WHEN ABS(cp_mom_pct_change) > 0.02 THEN unix_date END).
--   Then for each row, check if THIS row is the latest step row, and if so,
--   emit 'UP' or 'DOWN'. All other rows emit NULL.
-- Step 3 (combined_mom_resolved below): MAX(last_step_direction_raw) over the
--   full partition collapses NULLs — only the latest step row contributes a
--   non-NULL value, so MAX returns exactly that value for all rows in the key.
--
-- This avoids string-sort ambiguity ('DOWN' vs 'UP' lexicographic order) and
-- avoids any IGNORE NULLS syntax entirely.
combined_mom_directed AS (
    SELECT
        groupby_key,
        cal_month_start_dt,
        cust_prod_category,
        price_month,
        cp_mom_pct_change,
        wac_mom_pct_change,
        recent_wac_mom_change_if_in_window,
        CASE
            WHEN ABS(cp_mom_pct_change) > 0.02
             AND UNIX_DATE(cal_month_start_dt)
                 = MAX(CASE WHEN ABS(cp_mom_pct_change) > 0.02
                            THEN UNIX_DATE(cal_month_start_dt) END)
                   OVER (PARTITION BY groupby_key)
            THEN CASE WHEN cp_mom_pct_change > 0 THEN 'UP' ELSE 'DOWN' END
            ELSE NULL
        END                                             AS last_step_direction_raw
    FROM combined_mom_raw
),
-- Collapse: MAX(last_step_direction_raw) over the full partition propagates
-- the single non-NULL direction value to every row in the key.
-- 'UP' > 'DOWN' alphabetically, so if somehow two rows tie on the latest date
-- (one UP one DOWN), MAX returns 'UP' — acceptable edge case.
combined_mom AS (
    SELECT
        groupby_key,
        cal_month_start_dt,
        cust_prod_category,
        price_month,
        cp_mom_pct_change,
        wac_mom_pct_change,
        recent_wac_mom_change_if_in_window,
        MAX(last_step_direction_raw)
            OVER (PARTITION BY groupby_key)             AS last_step_direction
    FROM combined_mom_directed
),
-- ── typical_increase_month (APOLLO, BX, GLP-1, MPB Specialty, MPB Plasma) ─
typical_increase_month AS (
    SELECT
        groupby_key,
        price_month                                     AS typical_increase_month
    FROM (
        SELECT
            groupby_key,
            price_month,
            COUNT(*)                                    AS increase_count,
            AVG(cp_mom_pct_change)                      AS avg_increase
        FROM combined_mom
        WHERE cp_mom_pct_change > 0.02
        GROUP BY groupby_key, price_month
    )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY groupby_key
        ORDER BY increase_count DESC, avg_increase DESC
    ) = 1
),
-- ── step_history (APOLLO and BX only) ─────────────────────────────────────
step_history AS (
    SELECT
        groupby_key,
        SUM(CASE WHEN cp_mom_pct_change >  0.02 THEN 1 ELSE 0 END)
                                                        AS step_up_count,
        AVG(CASE WHEN cp_mom_pct_change >  0.02
                 THEN cp_mom_pct_change END)            AS avg_step_up_pct,
        SUM(CASE WHEN cp_mom_pct_change < -0.02 THEN 1 ELSE 0 END)
                                                        AS step_down_count,
        AVG(CASE WHEN cp_mom_pct_change < -0.02
                 THEN cp_mom_pct_change END)            AS avg_step_down_pct,
        MAX(last_step_direction)                        AS last_step_direction,
        AVG(recent_wac_mom_change_if_in_window)         AS recent_wac_avg_mom_change
    FROM combined_mom
    WHERE cust_prod_category IN ('APOLLO', 'BX')
    GROUP BY groupby_key
),
assembled AS (
    SELECT
        a.groupby_key,
        -- acct_classification: do NOT COALESCE to UNKNOWN — NULL must stay NULL
        -- so that IN ('340B-CP','340B-CE') and = 'WAC' checks fail correctly
        -- for keys where modeling_base has no acct_classification. UNKNOWN
        -- would silently route these keys to wrong trend branches.
        -- Step 5b uses e.acct_classification (eligibility table) as the
        -- authoritative point-in-time value; this column is for Step 4
        -- internal routing and diagnostic output only.
        pf.acct_classification                          AS acct_classification,
        COALESCE(pf.cust_prod_category,  'UNKNOWN')     AS cust_prod_category,
        COALESCE(pf.product_family,      'UNKNOWN')     AS product_family,
        pf.manufacturer_id,
        la.anchor_month,
        la.anchor_contract_price,
        la.anchor_wac_spread,
        sc.sap_months_bt                                AS sap_months,
        r6.recent_6m_months,
        r6.prior_6m_months,
        r6.recent_6m_avg_contract_price,
        r6.prior_6m_avg_contract_price,
        r6.recent_6m_avg_wac_spread,
        lo.latest_6_observed_months,
        lo.latest_6_observed_avg_contract_price,
        lo.latest_6_observed_avg_wac_spread,
        paw.post_anchor_avg_wac_spread,
        paw.post_anchor_months,
        pacp.post_anchor_avg_contract_price,
        pacp.post_anchor_cp_months,
        td.yoy_pairs_used,
        td.avg_yoy_pct,
        td.directional_consistency,
        COALESCE(tr.ols_slope / NULLIF(tr.avg_price_ref, 0), 0) AS raw_regression_trend_pct,
        COALESCE(tr.quarters_used, 0)                           AS regression_quarters_used,
        pft.pf_yoy_pairs_used,
        pft.pf_avg_yoy_pct,
        mft.mfr_yoy_pairs_used,
        mft.mfr_avg_yoy_pct,
        tim.typical_increase_month,
        sh.step_up_count,
        sh.avg_step_up_pct,
        sh.step_down_count,
        sh.avg_step_down_pct,
        sh.last_step_direction,
        sh.recent_wac_avg_mom_change
    FROM all_keys a
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_last_actual_v23       la   ON a.groupby_key = la.groupby_key
    LEFT JOIN sap_coverage                                                             sc   ON a.groupby_key = sc.groupby_key
    LEFT JOIN recent_6m                                                               r6   ON a.groupby_key = r6.groupby_key
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_latest_obs_v23        lo   ON a.groupby_key = lo.groupby_key
    LEFT JOIN post_anchor_wac                                                         paw  ON a.groupby_key = paw.groupby_key
    LEFT JOIN post_anchor_cp                                                          pacp ON a.groupby_key = pacp.groupby_key
    LEFT JOIN trend_direction                                                          td   ON a.groupby_key = td.groupby_key
    LEFT JOIN trend_regression                                                         tr   ON a.groupby_key = tr.groupby_key
    LEFT JOIN pf_lookup                                                                pf   ON a.groupby_key = pf.groupby_key
    LEFT JOIN pf_trend                                                                 pft  ON COALESCE(pf.product_family, 'UNKNOWN') = pft.product_family
    LEFT JOIN mfr_trend                                                                mft  ON pf.manufacturer_id = mft.manufacturer_id
    LEFT JOIN typical_increase_month                                                   tim  ON a.groupby_key = tim.groupby_key
    LEFT JOIN step_history                                                             sh   ON a.groupby_key = sh.groupby_key
),
guardrails AS (
    SELECT
        a.*,
        CASE
            WHEN COALESCE(a.yoy_pairs_used, 0) < 2                             THEN 0
            WHEN COALESCE(a.directional_consistency, 0) < 0.60                 THEN 0
            WHEN a.recent_6m_avg_contract_price IS NULL
              OR a.recent_6m_avg_contract_price = 0                            THEN 0
            WHEN ABS(a.anchor_contract_price
                / NULLIF(a.recent_6m_avg_contract_price, 0) - 1) > 0.20        THEN 0
            ELSE 1
        END                                                 AS sign_only_eligible,
        CASE
            WHEN a.latest_6_observed_avg_contract_price IS NULL
              OR a.latest_6_observed_avg_contract_price = 0  THEN 1
            WHEN a.anchor_contract_price
               / NULLIF(a.latest_6_observed_avg_contract_price, 0) >= 0.95     THEN 1
            ELSE 0
        END                                                 AS g5_recent_price_not_falling,
        CASE
            WHEN a.anchor_wac_spread IS NULL
              OR a.recent_6m_avg_wac_spread IS NULL          THEN 1
            WHEN (a.anchor_wac_spread - a.recent_6m_avg_wac_spread) > -0.30   THEN 1
            ELSE 0
        END                                                 AS wac_spread_ok,
        -- ── forecast_start_contract_price_raw ─────────────────────────────
        -- Computed here in guardrails because it needs wac_spread_ok (also
        -- computed here). The capped CTE then applies the 3x anchor cap.
        CASE
            WHEN a.cust_prod_category = 'APOLLO'
            THEN
                CASE
                    WHEN a.post_anchor_avg_contract_price IS NOT NULL
                     AND a.post_anchor_avg_contract_price > 0
                     AND a.anchor_contract_price IS NOT NULL
                     AND a.anchor_contract_price > 0
                     AND (a.post_anchor_avg_contract_price
                          / NULLIF(a.anchor_contract_price, 0)) < 0.97
                     AND a.post_anchor_cp_months >= 2
                    THEN a.post_anchor_avg_contract_price
                    ELSE a.anchor_contract_price
                END
            WHEN a.acct_classification != 'WAC'
             AND a.cust_prod_category  != 'APOLLO'
             AND a.post_anchor_avg_contract_price IS NOT NULL
             AND a.post_anchor_avg_contract_price  > 0
             AND a.recent_6m_avg_contract_price   IS NOT NULL
             AND a.recent_6m_avg_contract_price    > 0
             AND (a.post_anchor_avg_contract_price
                  / NULLIF(a.recent_6m_avg_contract_price, 0)) > 1.20
             AND (   a.post_anchor_cp_months >= 2
                  OR (a.post_anchor_avg_contract_price
                      / NULLIF(a.recent_6m_avg_contract_price, 0)) > 1.50)
            THEN a.post_anchor_avg_contract_price
            WHEN a.acct_classification != 'WAC'
             AND a.cust_prod_category  != 'APOLLO'
             AND a.post_anchor_avg_contract_price IS NOT NULL
             AND a.post_anchor_avg_contract_price  > 0
             AND a.recent_6m_avg_contract_price   IS NOT NULL
             AND a.recent_6m_avg_contract_price    > 0
             AND (a.post_anchor_avg_contract_price
                  / NULLIF(a.recent_6m_avg_contract_price, 0)) < 0.80
             AND (   a.post_anchor_cp_months >= 3
                  OR (a.post_anchor_avg_contract_price
                      / NULLIF(a.recent_6m_avg_contract_price, 0)) < 0.70)
            THEN a.post_anchor_avg_contract_price
            WHEN a.acct_classification = 'WAC'
             AND a.post_anchor_avg_wac_spread IS NOT NULL
             AND a.anchor_wac_spread IS NOT NULL
             AND (a.post_anchor_avg_wac_spread - a.anchor_wac_spread) < -0.05
             AND (   a.post_anchor_months >= 3
                  OR (a.post_anchor_avg_wac_spread - a.anchor_wac_spread) < -0.15)
            THEN
                GREATEST(
                    CASE
                        WHEN a.recent_6m_months >= 3
                         AND a.recent_6m_avg_contract_price IS NOT NULL
                         AND a.recent_6m_avg_contract_price > 0
                         AND wac_spread_ok = 1
                         AND (a.recent_6m_avg_contract_price / NULLIF(a.prior_6m_avg_contract_price, 0) >= 0.30
                              OR ABS(a.recent_6m_avg_contract_price / NULLIF(a.prior_6m_avg_contract_price, 0) - 1) <= 0.05
                              OR a.prior_6m_avg_contract_price > a.recent_6m_avg_contract_price * 5)
                         AND (a.cust_prod_category = 'GX'
                              OR a.anchor_contract_price / NULLIF(a.recent_6m_avg_contract_price, 0) >= 0.15)
                         AND (a.cust_prod_category = 'GX'
                              OR a.recent_6m_avg_contract_price / NULLIF(a.anchor_contract_price, 0) <= 1.5)
                        THEN a.recent_6m_avg_contract_price
                        WHEN a.latest_6_observed_months >= 3
                        THEN a.latest_6_observed_avg_contract_price
                        ELSE a.anchor_contract_price
                    END
                    * (1 + (a.post_anchor_avg_wac_spread - a.anchor_wac_spread)),
                0)
            ELSE
                CASE
                    WHEN a.recent_6m_months >= 3
                     AND a.recent_6m_avg_contract_price IS NOT NULL
                     AND a.recent_6m_avg_contract_price > 0
                     AND wac_spread_ok = 1
                     AND (a.recent_6m_avg_contract_price / NULLIF(a.prior_6m_avg_contract_price, 0) >= 0.30
                          OR ABS(a.recent_6m_avg_contract_price / NULLIF(a.prior_6m_avg_contract_price, 0) - 1) <= 0.05
                          OR a.prior_6m_avg_contract_price > a.recent_6m_avg_contract_price * 5)
                     AND (a.cust_prod_category = 'GX'
                          OR a.anchor_contract_price / NULLIF(a.recent_6m_avg_contract_price, 0) >= 0.15)
                     AND (a.cust_prod_category = 'GX'
                          OR a.recent_6m_avg_contract_price / NULLIF(a.anchor_contract_price, 0) <= 1.5)
                    THEN a.recent_6m_avg_contract_price
                    WHEN a.latest_6_observed_months >= 3
                    THEN a.latest_6_observed_avg_contract_price
                    ELSE a.anchor_contract_price
                END
        END                                                 AS forecast_start_contract_price_raw
    FROM assembled a
),
-- ── capped: apply 3x anchor cap to forecast_start_contract_price ─────────
-- forecast_start_contract_price_raw is computed in the final SELECT below
-- (it depends on g.wac_spread_ok which is only available in guardrails).
-- The cap cannot be applied in the same SELECT that computes the raw value
-- (SQL does not allow referencing a SELECT-level alias in the same SELECT).
-- Solution: capped CTE reads from guardrails, re-exposes all columns via g.*,
-- and computes the capped price and flag as additional columns.
-- The final SELECT reads from capped (aliased as g) — no other changes needed.
capped AS (
    SELECT
        g.*,
        -- ── forecast_start_contract_price cap ──────────────────────────────
        -- Cap at 3x anchor (upward only). Downward corrections are intentional.
        -- Explosion analysis: avg_start_to_anchor_ratio 3.9-8.6x, compound ~1.0.
        CASE
            WHEN g.anchor_contract_price IS NULL
              OR g.anchor_contract_price = 0
            THEN g.forecast_start_contract_price_raw
            WHEN g.forecast_start_contract_price_raw
                 / NULLIF(g.anchor_contract_price, 0) > 3.0
            THEN g.anchor_contract_price * 3.0
            ELSE g.forecast_start_contract_price_raw
        END                                                 AS forecast_start_contract_price,
        CASE
            WHEN g.anchor_contract_price IS NOT NULL
             AND g.anchor_contract_price > 0
             AND g.forecast_start_contract_price_raw
                 / NULLIF(g.anchor_contract_price, 0) > 3.0
            THEN 1 ELSE 0
        END                                                 AS forecast_start_price_capped_flag
    FROM guardrails g
)
SELECT
    g.groupby_key,
    g.cust_prod_category,
    g.acct_classification,                              -- Fix 14: added to output
    g.product_family,
    g.manufacturer_id,
    g.anchor_month,
    g.anchor_contract_price,
    g.anchor_wac_spread,
    g.sap_months,
    g.recent_6m_months,
    g.prior_6m_months,
    g.recent_6m_avg_contract_price,
    g.prior_6m_avg_contract_price,
    g.recent_6m_avg_wac_spread,
    g.latest_6_observed_months,
    g.latest_6_observed_avg_contract_price,
    g.latest_6_observed_avg_wac_spread,
    g.post_anchor_avg_wac_spread,
    g.post_anchor_months,
    g.post_anchor_avg_contract_price,
    g.post_anchor_cp_months,
    g.yoy_pairs_used,
    g.avg_yoy_pct,
    g.directional_consistency,
    g.raw_regression_trend_pct,
    g.regression_quarters_used,
    g.pf_yoy_pairs_used,
    g.pf_avg_yoy_pct,
    g.mfr_yoy_pairs_used,
    g.mfr_avg_yoy_pct,
    g.sign_only_eligible,
    g.g5_recent_price_not_falling,
    g.typical_increase_month,
    g.step_up_count,
    g.avg_step_up_pct,
    g.step_down_count,
    g.avg_step_down_pct,
    g.last_step_direction,
    g.recent_wac_avg_mom_change,
    -- ── forecast_start_wac_spread ──────────────────────────────────────────
    CASE
        WHEN g.cust_prod_category = 'APOLLO'
        THEN g.anchor_wac_spread
        WHEN g.recent_6m_months >= 3
         AND g.recent_6m_avg_wac_spread IS NOT NULL
         AND g.wac_spread_ok = 1
         AND (g.recent_6m_avg_contract_price / NULLIF(g.prior_6m_avg_contract_price, 0) >= 0.40
              OR ABS(g.recent_6m_avg_contract_price / NULLIF(g.prior_6m_avg_contract_price, 0) - 1) <= 0.05
              OR g.prior_6m_avg_contract_price > g.recent_6m_avg_contract_price * 5)
         AND (g.cust_prod_category = 'GX'
              OR g.anchor_contract_price / NULLIF(g.recent_6m_avg_contract_price, 0) >= 0.15)
         AND (g.cust_prod_category = 'GX'
              OR g.recent_6m_avg_contract_price / NULLIF(g.anchor_contract_price, 0) <= 1.5)
        THEN g.recent_6m_avg_wac_spread
        WHEN g.latest_6_observed_months >= 3
        THEN g.latest_6_observed_avg_wac_spread
        ELSE g.anchor_wac_spread
    END                                                     AS forecast_start_wac_spread,
    -- ── forecast_start_price_source ────────────────────────────────────────
    CASE
        WHEN g.cust_prod_category = 'APOLLO'
        THEN
            CASE
                WHEN g.post_anchor_avg_contract_price IS NOT NULL
                 AND g.post_anchor_avg_contract_price > 0
                 AND g.anchor_contract_price IS NOT NULL
                 AND g.anchor_contract_price > 0
                 AND (g.post_anchor_avg_contract_price
                      / NULLIF(g.anchor_contract_price, 0)) < 0.97
                 AND g.post_anchor_cp_months >= 2
                THEN 'APOLLO_POST_ANCHOR_PRICE_DROP_CORRECTION'
                ELSE 'APOLLO_ANCHOR_CONTRACT_PRICE'
            END
        WHEN g.acct_classification != 'WAC'
         AND g.cust_prod_category  != 'APOLLO'
         AND g.post_anchor_avg_contract_price IS NOT NULL
         AND g.post_anchor_avg_contract_price  > 0
         AND g.recent_6m_avg_contract_price   IS NOT NULL
         AND g.recent_6m_avg_contract_price    > 0
         AND (g.post_anchor_avg_contract_price
              / NULLIF(g.recent_6m_avg_contract_price, 0)) > 1.20
         AND (   g.post_anchor_cp_months >= 2
              OR (g.post_anchor_avg_contract_price
                  / NULLIF(g.recent_6m_avg_contract_price, 0)) > 1.50)
        THEN 'POST_ANCHOR_PRICE_INCREASE_CORRECTION'
        WHEN g.acct_classification != 'WAC'
         AND g.cust_prod_category  != 'APOLLO'
         AND g.post_anchor_avg_contract_price IS NOT NULL
         AND g.post_anchor_avg_contract_price  > 0
         AND g.recent_6m_avg_contract_price   IS NOT NULL
         AND g.recent_6m_avg_contract_price    > 0
         AND (g.post_anchor_avg_contract_price
              / NULLIF(g.recent_6m_avg_contract_price, 0)) < 0.80
         AND (   g.post_anchor_cp_months >= 3
              OR (g.post_anchor_avg_contract_price
                  / NULLIF(g.recent_6m_avg_contract_price, 0)) < 0.70)
        THEN 'POST_ANCHOR_PRICE_DROP_CORRECTION'
        WHEN g.acct_classification = 'WAC'
         AND g.post_anchor_avg_wac_spread IS NOT NULL
         AND g.anchor_wac_spread IS NOT NULL
         AND (g.post_anchor_avg_wac_spread - g.anchor_wac_spread) < -0.05
         AND (   g.post_anchor_months >= 3
              OR (g.post_anchor_avg_wac_spread - g.anchor_wac_spread) < -0.15)
        THEN
            CASE
                WHEN g.recent_6m_months >= 3
                 AND g.recent_6m_avg_contract_price IS NOT NULL
                 AND g.recent_6m_avg_contract_price > 0
                 AND g.wac_spread_ok = 1
                 AND (g.recent_6m_avg_contract_price / NULLIF(g.prior_6m_avg_contract_price, 0) >= 0.30
                      OR ABS(g.recent_6m_avg_contract_price / NULLIF(g.prior_6m_avg_contract_price, 0) - 1) <= 0.05
                      OR g.prior_6m_avg_contract_price > g.recent_6m_avg_contract_price * 5)
                 AND (g.cust_prod_category = 'GX'
                      OR g.anchor_contract_price / NULLIF(g.recent_6m_avg_contract_price, 0) >= 0.15)
                 AND (g.cust_prod_category = 'GX'
                      OR g.recent_6m_avg_contract_price / NULLIF(g.anchor_contract_price, 0) <= 1.5)
                THEN 'WAC_SPREAD_COMPRESSION_AVG_RECENT_6M_WITH_WAC_ADJ'
                WHEN g.latest_6_observed_months >= 3
                THEN 'WAC_SPREAD_COMPRESSION_AVG_LATEST_6_OBS_WITH_WAC_ADJ'
                ELSE 'WAC_SPREAD_COMPRESSION_ANCHOR_WITH_WAC_ADJ'
            END
        WHEN g.recent_6m_months >= 3
         AND g.recent_6m_avg_contract_price IS NOT NULL
         AND g.recent_6m_avg_contract_price > 0
         AND g.wac_spread_ok = 1
         AND (g.recent_6m_avg_contract_price / NULLIF(g.prior_6m_avg_contract_price, 0) >= 0.30
              OR ABS(g.recent_6m_avg_contract_price / NULLIF(g.prior_6m_avg_contract_price, 0) - 1) <= 0.05
              OR g.prior_6m_avg_contract_price > g.recent_6m_avg_contract_price * 5)
         AND (g.cust_prod_category = 'GX'
              OR g.anchor_contract_price / NULLIF(g.recent_6m_avg_contract_price, 0) >= 0.15)
         AND (g.cust_prod_category = 'GX'
              OR g.recent_6m_avg_contract_price / NULLIF(g.anchor_contract_price, 0) <= 1.5)
        THEN
            CASE
                WHEN g.acct_classification IN ('340B-CP','340B-CE')
                  OR g.cust_prod_category = 'GLP-1'
                  OR g.cust_prod_category = 'MPB Plasma'
                  OR g.product_family IN (
                    'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
                    'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
                    'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
                  )
                THEN 'AVG_RECENT_6M_WITH_REGRESSION_TREND'
                WHEN g.cust_prod_category = 'MPB Specialty'
                THEN 'AVG_RECENT_6M_WITH_AVG_YOY_TREND'
                WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
                THEN
                    CASE
                        WHEN g.g5_recent_price_not_falling = 1 AND ABS(g.avg_yoy_pct) > 0.03
                        THEN 'AVG_RECENT_6M_WITH_AVG_YOY_TREND_PROMOTED'
                        WHEN g.g5_recent_price_not_falling = 1
                        THEN 'AVG_RECENT_6M_WITH_SIGN_ONLY_TREND'
                        WHEN g.avg_yoy_pct <= 0
                        THEN 'AVG_RECENT_6M_WITH_AVG_YOY_TREND_PROMOTED'
                        ELSE 'AVG_RECENT_6M_NO_TREND_G5_RECENT_PRICE_DROP'
                    END
                ELSE 'AVG_RECENT_6M_NO_TREND'
            END
        WHEN g.latest_6_observed_months >= 3
        THEN
            CASE
                WHEN g.acct_classification IN ('340B-CP','340B-CE')
                  OR g.cust_prod_category = 'GLP-1'
                  OR g.cust_prod_category = 'MPB Plasma'
                  OR g.product_family IN (
                    'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
                    'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
                    'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
                  )
                THEN 'AVG_LATEST_6_OBS_WITH_REGRESSION_TREND'
                WHEN g.cust_prod_category = 'MPB Specialty'
                THEN 'AVG_LATEST_6_OBS_WITH_AVG_YOY_TREND'
                WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
                THEN
                    CASE
                        WHEN g.g5_recent_price_not_falling = 1 AND ABS(g.avg_yoy_pct) > 0.03
                        THEN 'AVG_LATEST_6_OBS_WITH_AVG_YOY_TREND_PROMOTED'
                        WHEN g.g5_recent_price_not_falling = 1
                        THEN 'AVG_LATEST_6_OBS_WITH_SIGN_ONLY_TREND'
                        WHEN g.avg_yoy_pct <= 0
                        THEN 'AVG_LATEST_6_OBS_WITH_AVG_YOY_TREND_PROMOTED'
                        ELSE 'AVG_LATEST_6_OBS_NO_TREND_G5_RECENT_PRICE_DROP'
                    END
                ELSE 'AVG_LATEST_6_OBS_NO_TREND'
            END
        WHEN g.latest_6_observed_months > 0
        THEN 'LATEST_PRICE_LT_3_OBSERVED_MONTHS_NO_TREND'
        ELSE 'NO_HISTORY_AVAILABLE'
    END                                                     AS forecast_start_price_source,
    -- forecast_start_contract_price and forecast_start_price_capped_flag are
    -- computed in the capped CTE (above guardrails) and passed through here.
    -- They cannot be computed in this SELECT because the raw value is also
    -- computed here and SQL does not allow self-referencing SELECT aliases.
    g.forecast_start_contract_price,
    g.forecast_start_price_capped_flag,
    -- ── expected_monthly_trend_pct ─────────────────────────────────────────
    -- Cap lift applied per segment based on diagnostic data (pct_clipped_high_confidence):
    --   APOLLO        ±15%: legitimate specialty drug step-ups exceed ±2%
    --   MPB Specialty ±15%: 97-100% high confidence across all clipped buckets
    --   BX non-340B   ±15%: 1.5M+ keys, 94-99% high confidence
    --   DROP SHIP non-340B ±10%: high confidence but lower sap_months → conservative
    --   All others    ±2%:  GX/BIOSIMS/OTC/VAX retain — outlier avg_raw_yoy_pct
    --                       values indicate cap is doing real noise suppression
    -- Fix 13: Dead BX non-340B sparse fallback block removed from ELSE branch.
    --   BX non-340B is fully captured by its own ±15% WHEN block above ELSE.
    CASE
        -- ── APOLLO: ±15% cap ──────────────────────────────────────────────
        WHEN g.cust_prod_category = 'APOLLO'
        THEN GREATEST(-0.15, LEAST(0.15,
            CASE
                -- Step history guard: requires directional_consistency >= 0.60
                -- and avg_yoy_pct sign agreement.
                -- step_up_count >= 2: tightened from >= 1 — single step-up events
                -- added noise (WMAPE 3.08% vs AVG_YOY 2.68%). Two confirmed
                -- step-ups required before trusting magnitude.
                -- STEP_DOWN disabled for APOLLO: WMAPE 13.17% vs 2.68% for AVG_YOY.
                -- WAC confirmation is only 2.2% reliable for APOLLO step-downs
                -- (documented in v23d changelog). Falls through to avg_yoy chain.
                WHEN COALESCE(g.step_up_count, 0) >= 2
                 AND g.last_step_direction = 'UP'
                 AND COALESCE(g.avg_yoy_pct, 0) >= 0
                 AND COALESCE(g.directional_consistency, 0) >= 0.60
                THEN g.avg_step_up_pct
                WHEN COALESCE(g.yoy_pairs_used, 0) >= 1    THEN g.avg_yoy_pct
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2 THEN g.pf_avg_yoy_pct
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2 THEN g.mfr_avg_yoy_pct
                ELSE 0.0
            END))
        -- ── MPB Specialty: ±15% cap ───────────────────────────────────────
        WHEN g.cust_prod_category = 'MPB Specialty'
        THEN GREATEST(-0.15, LEAST(0.15,
            CASE
                -- 340B-CP/CE MPB Specialty uses regression (quarterly OLS slope)
                -- to match the trend method and avoid annual/quarterly mismatch
                -- in Step 8 compounding.
                WHEN g.acct_classification IN ('340B-CP','340B-CE')
                THEN CASE
                    WHEN COALESCE(g.regression_quarters_used, 0) >= 3
                     AND COALESCE(g.directional_consistency, 0) >= 0.60
                     AND ABS(g.raw_regression_trend_pct) <= 0.15
                    THEN g.raw_regression_trend_pct
                    ELSE 0.0
                END
                WHEN COALESCE(g.yoy_pairs_used, 0) >= 1    THEN g.avg_yoy_pct
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2 THEN g.pf_avg_yoy_pct
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2 THEN g.mfr_avg_yoy_pct
                ELSE 0.0
            END))
        -- ── BX non-340B: ±15% cap ─────────────────────────────────────────
        WHEN g.cust_prod_category = 'BX'
         AND g.acct_classification NOT IN ('340B-CP','340B-CE')
        THEN GREATEST(-0.15, LEAST(0.15,
            CASE
                WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
                THEN
                    CASE
                        -- BX STEP_DOWN_HISTORY disabled (WMAPE 16.24% vs NO_TREND 9.63%).
                        -- WAC confirmation for step-downs is noisy; falls through
                        -- to sign_only / AVG_YOY_PROMOTED logic below.
                        WHEN g.product_family NOT IN (
                             'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
                             'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
                             'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
                         )
                         AND COALESCE(g.step_up_count, 0) >= 2
                         AND g.last_step_direction = 'UP'
                         AND g.recent_wac_avg_mom_change > 0
                         AND COALESCE(g.avg_yoy_pct, 0) >= 0
                         AND COALESCE(g.directional_consistency, 0) >= 0.60
                        THEN g.avg_step_up_pct
                        WHEN g.g5_recent_price_not_falling = 1
                         AND g.directional_consistency >= 0.80
                        THEN CASE
                              -- Full rate when all YOY pairs agree (dc=1.0) and
                              -- trend is meaningful and direction is positive.
                              -- Covers XARELTO, ELIQUIS, JANUVIA etc. which have
                              -- perfectly consistent annual increases.
                              -- GX excluded even at dc=1.0: generic price declines
                              -- are non-linear and accelerate unpredictably —
                              -- full undampened negative rate overshoots downward.
                              -- Negative trends retain 0.19x dampening for all segments.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.directional_consistency = 1.0
                               AND g.avg_yoy_pct > 0
                               AND g.cust_prod_category != 'GX'
                              THEN g.avg_yoy_pct
                              -- GX positive trend: route to SIGN_ONLY (±1%) instead
                              -- of * 0.19. GX AVG_YOY_PROMOTED WMAPE = 18.82% vs
                              -- SIGN_ONLY_025PCT = 7.46% — positive YOY trend on GX
                              -- overshoots because latest observed price already
                              -- incorporates recent increase. SIGN_ONLY is safer.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.avg_yoy_pct > 0
                               AND g.cust_prod_category = 'GX'
                              THEN 0.01
                              -- Dampened rate (0.19x) for directionally
                              -- consistent but not perfectly uniform keys.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                              THEN g.avg_yoy_pct * 0.19
                              WHEN g.avg_yoy_pct > 0 THEN  0.01
                              WHEN g.avg_yoy_pct < 0 THEN -0.01
                              ELSE 0.0
                          END
                        WHEN g.g5_recent_price_not_falling = 1
                        THEN CASE WHEN g.avg_yoy_pct > 0 THEN  0.01
                                  WHEN g.avg_yoy_pct < 0 THEN -0.01
                                  ELSE 0.0 END
                        WHEN g.avg_yoy_pct <= 0
                         AND g.directional_consistency >= 0.80
                    THEN CASE
                        -- GX negative trend: route to SIGN_ONLY (-1%) instead
                        -- of * 0.19. GX AVG_YOY_PROMOTED WMAPE = 22.58% for
                        -- negative keys vs NO_TREND 14.24% and SIGN_ONLY 7.46%.
                        -- Generic price declines are non-linear and the dampened
                        -- YOY rate still overshoots downward for GX.
                        WHEN g.cust_prod_category = 'GX' THEN -0.01
                        ELSE g.avg_yoy_pct * 0.19
                    END
                    -- Negative trends always dampened regardless of dc (non-GX).
                    -- Generic price declines are non-linear and accelerate,
                    -- so full undampened negative rates overshoot downward.
                        ELSE 0.0
                    END
                -- BX non-340B sparse fallback (negative-only)
                WHEN COALESCE(g.yoy_pairs_used, 0) < 2
                 AND g.product_family NOT IN (
                    'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
                    'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
                    'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
                 )
                THEN
                    CASE
                        WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2
                         AND g.pf_avg_yoy_pct < 0  THEN g.pf_avg_yoy_pct
                        WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2
                         AND g.mfr_avg_yoy_pct < 0 THEN g.mfr_avg_yoy_pct
                        ELSE 0.0
                    END
                ELSE 0.0
            END))
        -- ── DROP SHIP non-340B: ±10% cap ──────────────────────────────────
        WHEN g.cust_prod_category = 'DROP SHIP'
         AND g.acct_classification NOT IN ('340B-CP','340B-CE')
        THEN GREATEST(-0.10, LEAST(0.10,
            CASE
                WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
                THEN
                    CASE
                        WHEN g.g5_recent_price_not_falling = 1
                         AND g.directional_consistency >= 0.80
                        THEN CASE
                              -- Full rate when all YOY pairs agree (dc=1.0) and
                              -- trend is meaningful and direction is positive.
                              -- Covers XARELTO, ELIQUIS, JANUVIA etc. which have
                              -- perfectly consistent annual increases.
                              -- GX excluded even at dc=1.0: generic price declines
                              -- are non-linear and accelerate unpredictably —
                              -- full undampened negative rate overshoots downward.
                              -- Negative trends retain 0.19x dampening for all segments.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.directional_consistency = 1.0
                               AND g.avg_yoy_pct > 0
                               AND g.cust_prod_category != 'GX'
                              THEN g.avg_yoy_pct
                              -- GX positive trend: route to SIGN_ONLY (±1%) instead
                              -- of * 0.19. GX AVG_YOY_PROMOTED WMAPE = 18.82% vs
                              -- SIGN_ONLY_025PCT = 7.46% — positive YOY trend on GX
                              -- overshoots because latest observed price already
                              -- incorporates recent increase. SIGN_ONLY is safer.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.avg_yoy_pct > 0
                               AND g.cust_prod_category = 'GX'
                              THEN 0.01
                              -- Dampened rate (0.19x) for directionally
                              -- consistent but not perfectly uniform keys.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                              THEN g.avg_yoy_pct * 0.19
                              WHEN g.avg_yoy_pct > 0 THEN  0.01
                              WHEN g.avg_yoy_pct < 0 THEN -0.01
                              ELSE 0.0
                          END
                        WHEN g.g5_recent_price_not_falling = 1
                        THEN CASE WHEN g.avg_yoy_pct > 0 THEN  0.01
                                  WHEN g.avg_yoy_pct < 0 THEN -0.01
                                  ELSE 0.0 END
                        WHEN g.avg_yoy_pct <= 0
                         AND g.directional_consistency >= 0.80
                    THEN CASE
                        -- GX negative trend: route to SIGN_ONLY (-1%) instead
                        -- of * 0.19. GX AVG_YOY_PROMOTED WMAPE = 22.58% for
                        -- negative keys vs NO_TREND 14.24% and SIGN_ONLY 7.46%.
                        -- Generic price declines are non-linear and the dampened
                        -- YOY rate still overshoots downward for GX.
                        WHEN g.cust_prod_category = 'GX' THEN -0.01
                        ELSE g.avg_yoy_pct * 0.19
                    END
                    -- Negative trends always dampened regardless of dc (non-GX).
                    -- Generic price declines are non-linear and accelerate,
                    -- so full undampened negative rates overshoot downward.
                        ELSE 0.0
                    END
                ELSE 0.0
            END))
        -- ── All other segments: ±2% cap (unchanged) ───────────────────────
        ELSE GREATEST(-0.02, LEAST(0.02,
            CASE
                WHEN g.cust_prod_category = 'GLP-1'
                THEN CASE
                    WHEN COALESCE(g.regression_quarters_used, 0) >= 3
                     AND COALESCE(g.directional_consistency, 0) >= 0.60
                     AND ABS(g.raw_regression_trend_pct) <= 0.15
                    THEN g.raw_regression_trend_pct
                    ELSE 0.0
                END
                WHEN g.cust_prod_category = 'MPB Plasma'
                THEN CASE
                    WHEN COALESCE(g.regression_quarters_used, 0) >= 3
                     AND COALESCE(g.directional_consistency, 0) >= 0.60
                     AND ABS(g.raw_regression_trend_pct) <= 0.15
                    THEN g.raw_regression_trend_pct
                    ELSE 0.0
                END
                WHEN g.product_family IN (
                    'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
                    'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
                    'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
                )
                THEN CASE
                    WHEN COALESCE(g.regression_quarters_used, 0) >= 3
                     AND COALESCE(g.directional_consistency, 0) >= 0.60
                     AND ABS(g.raw_regression_trend_pct) <= 0.15
                    THEN g.raw_regression_trend_pct
                    ELSE 0.0
                END
                WHEN g.acct_classification IN ('340B-CP','340B-CE')
                 AND g.cust_prod_category NOT IN ('APOLLO','GLP-1','MPB Specialty','MPB Plasma')
                THEN CASE
                    WHEN COALESCE(g.regression_quarters_used, 0) >= 3
                     AND COALESCE(g.directional_consistency, 0) >= 0.60
                     AND ABS(g.raw_regression_trend_pct) <= 0.15
                    THEN g.raw_regression_trend_pct
                    ELSE 0.0
                END
                WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
                THEN
                    CASE
                        -- BX 340B step history (stays in ±2% cap; WAC confirmation required)
                        WHEN g.cust_prod_category = 'BX'
                         AND g.product_family NOT IN (
                             'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
                             'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
                             'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
                         )
                         AND COALESCE(g.step_up_count, 0) >= 2
                         AND g.last_step_direction = 'UP'
                         AND g.recent_wac_avg_mom_change > 0
                        THEN g.avg_step_up_pct
                        -- BX 340B STEP_DOWN_HISTORY disabled (consistent with BX non-340B)
                        WHEN g.g5_recent_price_not_falling = 1
                         AND g.directional_consistency >= 0.80
                        THEN CASE
                              -- Full rate when all YOY pairs agree (dc=1.0) and
                              -- trend is meaningful and direction is positive.
                              -- Covers XARELTO, ELIQUIS, JANUVIA etc. which have
                              -- perfectly consistent annual increases.
                              -- GX excluded even at dc=1.0: generic price declines
                              -- are non-linear and accelerate unpredictably —
                              -- full undampened negative rate overshoots downward.
                              -- Negative trends retain 0.19x dampening for all segments.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.directional_consistency = 1.0
                               AND g.avg_yoy_pct > 0
                               AND g.cust_prod_category != 'GX'
                              THEN g.avg_yoy_pct
                              -- GX positive trend: route to SIGN_ONLY (±1%) instead
                              -- of * 0.19. GX AVG_YOY_PROMOTED WMAPE = 18.82% vs
                              -- SIGN_ONLY_025PCT = 7.46% — positive YOY trend on GX
                              -- overshoots because latest observed price already
                              -- incorporates recent increase. SIGN_ONLY is safer.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.avg_yoy_pct > 0
                               AND g.cust_prod_category = 'GX'
                              THEN 0.01
                              -- Dampened rate (0.19x) for directionally
                              -- consistent but not perfectly uniform keys.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                              THEN g.avg_yoy_pct * 0.19
                              WHEN g.avg_yoy_pct > 0 THEN  0.01
                              WHEN g.avg_yoy_pct < 0 THEN -0.01
                              ELSE 0.0
                          END
                        WHEN g.g5_recent_price_not_falling = 1
                        THEN CASE WHEN g.avg_yoy_pct > 0 THEN  0.01
                                  WHEN g.avg_yoy_pct < 0 THEN -0.01
                                  ELSE 0.0 END
                        WHEN g.avg_yoy_pct <= 0
                         AND g.directional_consistency >= 0.80
                    THEN CASE
                        -- GX negative trend: route to SIGN_ONLY (-1%) instead
                        -- of * 0.19. GX AVG_YOY_PROMOTED WMAPE = 22.58% for
                        -- negative keys vs NO_TREND 14.24% and SIGN_ONLY 7.46%.
                        -- Generic price declines are non-linear and the dampened
                        -- YOY rate still overshoots downward for GX.
                        WHEN g.cust_prod_category = 'GX' THEN -0.01
                        ELSE g.avg_yoy_pct * 0.19
                    END
                    -- Negative trends always dampened regardless of dc (non-GX).
                    -- Generic price declines are non-linear and accelerate,
                    -- so full undampened negative rates overshoot downward.
                        ELSE 0.0
                    END
                ELSE 0.0
            END))
    END                                                     AS expected_monthly_trend_pct,
    -- ── assigned_trend_method ──────────────────────────────────────────────
    CASE
        WHEN g.cust_prod_category = 'APOLLO'
        THEN
            CASE
                WHEN COALESCE(g.step_up_count, 0) >= 2
                 AND g.last_step_direction = 'UP'
                 AND COALESCE(g.avg_yoy_pct, 0) >= 0
                 AND COALESCE(g.directional_consistency, 0) >= 0.60    THEN 'STEP_UP_HISTORY'
                -- STEP_DOWN_HISTORY disabled for APOLLO (WMAPE 13.17% vs AVG_YOY 2.68%)
                WHEN COALESCE(g.yoy_pairs_used, 0) >= 1    THEN 'AVG_YOY'
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2 THEN 'PF_AVG_YOY'
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2 THEN 'MFR_AVG_YOY'
                ELSE 'NO_TREND'
            END
        WHEN g.cust_prod_category = 'GLP-1'
        THEN CASE
            WHEN COALESCE(g.regression_quarters_used, 0) >= 3
             AND COALESCE(g.directional_consistency, 0) >= 0.60
             AND ABS(g.raw_regression_trend_pct) <= 0.15   THEN 'REGRESSION'
            ELSE 'NO_TREND'
        END
        WHEN g.cust_prod_category = 'MPB Specialty'
        THEN
            CASE
                -- 340B-CP/CE MPB Specialty gets REGRESSION (quarterly OLS slope)
                -- to match forecast_start_price_source = REGRESSION_TREND label.
                -- Without this, 340B MPB Specialty gets AVG_YOY (annual rate)
                -- but Step 8 quarterly compounding applies, causing 2.46x compound
                -- ratio explosions (annual rate compounded 8x quarterly).
                WHEN g.acct_classification IN ('340B-CP','340B-CE') THEN 'REGRESSION'
                WHEN COALESCE(g.yoy_pairs_used, 0) >= 1    THEN 'AVG_YOY'
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2 THEN 'PF_AVG_YOY'
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2 THEN 'MFR_AVG_YOY'
                ELSE 'NO_TREND'
            END
        WHEN g.cust_prod_category = 'MPB Plasma'
        THEN CASE
            WHEN COALESCE(g.regression_quarters_used, 0) >= 3
             AND COALESCE(g.directional_consistency, 0) >= 0.60
             AND ABS(g.raw_regression_trend_pct) <= 0.15   THEN 'REGRESSION'
            ELSE 'NO_TREND'
        END
        WHEN g.product_family IN (
            'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
            'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
            'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
        )
        THEN CASE
            WHEN COALESCE(g.regression_quarters_used, 0) >= 3
             AND COALESCE(g.directional_consistency, 0) >= 0.60
             AND ABS(g.raw_regression_trend_pct) <= 0.15   THEN 'REGRESSION'
            ELSE 'NO_TREND'
        END
        WHEN g.acct_classification IN ('340B-CP','340B-CE')
         AND g.cust_prod_category NOT IN ('APOLLO','GLP-1','MPB Specialty','MPB Plasma')
        THEN CASE
            WHEN COALESCE(g.regression_quarters_used, 0) >= 3
             AND COALESCE(g.directional_consistency, 0) >= 0.60
             AND ABS(g.raw_regression_trend_pct) <= 0.15   THEN 'REGRESSION'
            ELSE 'NO_TREND'
        END
        WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
        THEN
            CASE
                WHEN g.cust_prod_category = 'BX'
                 AND g.acct_classification NOT IN ('340B-CP','340B-CE')
                 AND g.product_family NOT IN (
                     'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
                     'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
                     'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
                 )
                 AND COALESCE(g.step_up_count, 0) >= 2
                 AND g.last_step_direction = 'UP'
                 AND g.recent_wac_avg_mom_change > 0
                 AND COALESCE(g.avg_yoy_pct, 0) >= 0
                 AND COALESCE(g.directional_consistency, 0) >= 0.60    THEN 'STEP_UP_HISTORY'
                -- BX STEP_DOWN_HISTORY disabled (WMAPE 16.24% vs NO_TREND 9.63%)
                WHEN g.g5_recent_price_not_falling = 1
                 AND g.directional_consistency >= 0.80
                THEN CASE
                         -- GX: both positive and negative demoted to SIGN_ONLY
                         -- AVG_YOY_PROMOTED WMAPE = 22.58% vs SIGN_ONLY 7.46% for GX
                         WHEN g.cust_prod_category = 'GX'   THEN 'SIGN_ONLY_025PCT'
                         WHEN ABS(g.avg_yoy_pct) > 0.03     THEN 'AVG_YOY_PROMOTED'
                         ELSE 'SIGN_ONLY_025PCT'
                     END
                WHEN g.g5_recent_price_not_falling = 1
                THEN 'SIGN_ONLY_025PCT'
                WHEN g.avg_yoy_pct <= 0
                 AND g.directional_consistency >= 0.80
                THEN CASE
                    -- GX negative demoted to SIGN_ONLY (matches rate applied)
                    WHEN g.cust_prod_category = 'GX' THEN 'SIGN_ONLY_025PCT'
                    ELSE 'AVG_YOY_PROMOTED'
                END
                ELSE 'NO_TREND'
            END
        WHEN g.cust_prod_category = 'BX'
         AND COALESCE(g.yoy_pairs_used, 0) < 2
         AND g.acct_classification NOT IN ('340B-CP','340B-CE')
         AND g.product_family NOT IN (
            'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
            'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
            'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
         )
        THEN
            CASE
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2
                 AND g.pf_avg_yoy_pct < 0                  THEN 'PF_AVG_YOY'
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2
                 AND g.mfr_avg_yoy_pct < 0                 THEN 'MFR_AVG_YOY'
                ELSE 'NO_TREND'
            END
        ELSE 'NO_TREND'
    END                                                     AS assigned_trend_method,
    -- Fix 15: trend_cap_applied diagnostic column
    -- Indicates which outer cap bound was applied for each key.
    -- Enables QA of cap-lifted segments without inspecting CASE logic.
    CASE
        WHEN g.cust_prod_category = 'APOLLO'                                THEN '±15%'
        WHEN g.cust_prod_category = 'MPB Specialty'                         THEN '±15%'
        WHEN g.cust_prod_category = 'BX'
         AND g.acct_classification NOT IN ('340B-CP','340B-CE')             THEN '±15%'
        WHEN g.cust_prod_category = 'DROP SHIP'
         AND g.acct_classification NOT IN ('340B-CP','340B-CE')             THEN '±10%'
        ELSE '±2%'
    END                                                     AS trend_cap_applied,
    CASE
        WHEN g.latest_6_observed_months >= 6 THEN 'PRICE_6MO_AVG'
        WHEN g.latest_6_observed_months >= 3 THEN 'PRICE_3_TO_5_MO_AVG'
        WHEN g.latest_6_observed_months >= 1 THEN 'PRICE_LAST_OBSERVED'
        ELSE 'NO_PRICE_AVAILABLE'
    END                                                     AS sparse_price_confidence,
    CASE WHEN g.latest_6_observed_months < 6 THEN 1 ELSE 0 END AS is_sparse_price_flag
FROM capped g
;


-- =========================================================
-- STEP 4 QA QUERIES
-- =========================================================

-- Q1: Keys switching from NO_TREND to fallback method by tier and category
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key) AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('PF_AVG_YOY','MFR_AVG_YOY')
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category, assigned_trend_method;

-- Q2: Bias check — avg expected_monthly_trend_pct pre/post fallback
-- Compare keys using fallback vs key-level AVG_YOY within same category
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key)                             AS key_count,
    ROUND(AVG(expected_monthly_trend_pct) * 100, 3)        AS avg_trend_pct,
    ROUND(AVG(avg_yoy_pct) * 100, 3)                       AS avg_raw_yoy_pct
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category, assigned_trend_method;

-- Q3: Confirm no key-level trend was overridden by fallback
-- Any key with yoy_pairs_used >= 2 should NOT have PF_AVG_YOY or MFR_AVG_YOY
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('PF_AVG_YOY','MFR_AVG_YOY')
  AND COALESCE(yoy_pairs_used, 0) >= 2;

-- Q4: PF/MFR avg_yoy_pct variance vs key-level for switched keys
SELECT
    cust_prod_category,
    assigned_trend_method,
    ROUND(STDDEV(pf_avg_yoy_pct) * 100, 3)                 AS pf_trend_stddev,
    ROUND(STDDEV(mfr_avg_yoy_pct) * 100, 3)                AS mfr_trend_stddev,
    ROUND(STDDEV(avg_yoy_pct) * 100, 3)                    AS key_trend_stddev
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('PF_AVG_YOY','MFR_AVG_YOY','AVG_YOY')
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category;

-- Q5: Step history coverage — confirm only APOLLO and BX have step history
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key) AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('STEP_UP_HISTORY','STEP_DOWN_HISTORY')
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category;

-- Q6: Step magnitude sanity — avg/p50 of expected_monthly_trend_pct
-- by step method. Expect APOLLO ~+5% up, ~-7% down; BX ~+5% up, ~-42% down.
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key)                             AS key_count,
    ROUND(AVG(expected_monthly_trend_pct) * 100, 2)        AS avg_trend_pct,
    ROUND(PERCENTILE(expected_monthly_trend_pct, 0.5) * 100, 2) AS p50_trend_pct,
    ROUND(MIN(expected_monthly_trend_pct) * 100, 2)        AS min_trend_pct,
    ROUND(MAX(expected_monthly_trend_pct) * 100, 2)        AS max_trend_pct
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('STEP_UP_HISTORY','STEP_DOWN_HISTORY')
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category, assigned_trend_method;

-- Q7: Cap lift validation — pct of keys at or near the cap boundary
-- by segment. High pct at boundary for ±15%/±10% segments confirms
-- cap was previously binding and lift was warranted.
SELECT
    trend_cap_applied,
    cust_prod_category,
    acct_classification,
    COUNT(DISTINCT groupby_key)                             AS key_count,
    SUM(CASE WHEN ABS(expected_monthly_trend_pct) >= 0.149 THEN 1 ELSE 0 END)
                                                            AS at_15pct_cap,
    SUM(CASE WHEN ABS(expected_monthly_trend_pct) >= 0.099 THEN 1 ELSE 0 END)
                                                            AS at_10pct_cap,
    SUM(CASE WHEN ABS(expected_monthly_trend_pct) >= 0.019 THEN 1 ELSE 0 END)
                                                            AS at_2pct_cap,
    ROUND(AVG(expected_monthly_trend_pct) * 100, 3)        AS avg_trend_pct
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
GROUP BY trend_cap_applied, cust_prod_category, acct_classification
ORDER BY trend_cap_applied, cust_prod_category, acct_classification;

-- Q8: Confirm acct_classification is populated (Fix 14 validation)
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN acct_classification IS NULL     THEN 1 ELSE 0 END) AS null_acct_class,
    SUM(CASE WHEN acct_classification = 'UNKNOWN' THEN 1 ELSE 0 END) AS unknown_acct_class
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23;