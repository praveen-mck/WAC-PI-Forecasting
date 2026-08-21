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
-- Fixes backported from BT v23 (see BT changelog for full detail):
--
--   Fix 20 — pf_trend / mfr_trend extreme YOY pair filter.
--     AVG in pf_trend and mfr_trend now filters ABS(yoy_pct) <= 5.0
--     before averaging, matching BT. Previously plain AVG was used,
--     allowing extreme pairs to contaminate family/manufacturer rates.
--
--   Fix 21 — combined_mom_raw filters to include_for_modeling_flag = 1.
--     Spike/outlier months excluded from MoM calculations, matching BT.
--
--   Fix 23 — NULL avg_yoy_pct propagation through APOLLO/MPB Specialty.
--     yoy_pairs_used_filtered added to trend_direction: counts only pairs
--     that passed the ABS <= 5.0 filter. APOLLO and MPB Specialty AVG_YOY
--     fallback in expected_monthly_trend_pct and assigned_trend_method now
--     gate on yoy_pairs_used_filtered >= 1 instead of yoy_pairs_used >= 1.
--     COALESCE(avg_yoy_pct, 0.0) added as final safety net.
--     yoy_pairs_used_filtered forwarded through assembled CTE and final SELECT.
--
--   Fix 24 — sign_only_eligible = 1 when anchor_contract_price is NULL.
--     Explicit WHEN anchor_contract_price IS NULL THEN 0 added as the first
--     branch of the sign_only_eligible CASE in guardrails, before the ratio
--     check. Without this, NULL anchor evaluates to UNKNOWN under ANSI
--     three-valued logic and falls through to ELSE 1 incorrectly.
--
--   Fix 25 — Dead GX branches inside BX expected_monthly_trend_pct block.
--     AND g.cust_prod_category != 'GX' / = 'GX' conditions removed from
--     the BX non-340B ±15% WHEN block. BX is never GX so these were always
--     false/true respectively. No numeric impact but inconsistent with Fix 22
--     applied to BT and a maintenance risk.
--
-- BT-only logic also backported:
--   - APOLLO forecast_start_contract_price_raw: post-anchor increase
--     correction branch (ratio BETWEEN 1.03 AND 2.0) added.
--   - APOLLO step-up: typical_increase_month gating added to
--     forecast_start_contract_price_raw, expected_monthly_trend_pct,
--     forecast_start_price_source, and assigned_trend_method.
--   - step_history CTE: typical_increase_month_step_up_pct and
--     typical_increase_month_step_up_count columns added via join
--     to typical_increase_month.
--   - post_anchor thresholds aligned to BT (non-APOLLO non-WAC: >= 2 months
--     required unconditionally; WAC: >= 2 months required).
--
-- Previously applied fixes retained:
--   Fix 12 — Nested window functions split into combined_mom_raw /
--     combined_mom_directed / combined_mom.
--   Fix 13 — Dead BX sparse fallback block removed from ELSE ±2% branch.
--   Fix 14 — acct_classification added to final SELECT.
--   Fix 15 — trend_cap_applied diagnostic column added to final SELECT.
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
        -- yoy_pairs_used counts ALL pairs for eligibility thresholds
        -- (>= 1, >= 2) so extreme pairs do not affect eligibility.
        COUNT(*)                                        AS yoy_pairs_used,
        -- Fix 23: yoy_pairs_used_filtered counts only pairs that passed
        -- the ABS <= 5.0 filter. Used to gate AVG_YOY fallback in APOLLO
        -- and MPB Specialty so a key with yoy_pairs_used=1 but avg_yoy_pct=NULL
        -- (because its only pair was extreme) does not fire the >= 1 gate
        -- and propagate NULL into GREATEST/LEAST under ANSI semantics.
        COUNT(CASE WHEN ABS(yoy_pct) <= 5.0 THEN 1 END)
                                                        AS yoy_pairs_used_filtered,
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
        -- Fix 20: filter extreme YOY pairs before averaging
        AVG(CASE WHEN ABS(yy.yoy_pct) <= 5.0 THEN yy.yoy_pct END)
                                                        AS pf_avg_yoy_pct
    FROM yearly_yoy yy
    JOIN pf_lookup pf ON yy.groupby_key = pf.groupby_key
    WHERE pf.product_family IS NOT NULL
    GROUP BY pf.product_family
),
mfr_trend AS (
    SELECT
        pf.manufacturer_id,
        COUNT(*)                                        AS mfr_yoy_pairs_used,
        -- Fix 20: filter extreme YOY pairs before averaging
        AVG(CASE WHEN ABS(yy.yoy_pct) <= 5.0 THEN yy.yoy_pct END)
                                                        AS mfr_avg_yoy_pct
    FROM yearly_yoy yy
    JOIN pf_lookup pf ON yy.groupby_key = pf.groupby_key
    WHERE pf.manufacturer_id IS NOT NULL
    GROUP BY pf.manufacturer_id
),
-- ── Fix 12 + Fix 21: merged combined_mom_raw ──────────────────────────────
-- Single scan of contract_price_training_clean_v23 for all APOLLO, BX,
-- GLP-1, MPB Specialty, MPB Plasma keys.
-- Fix 21: include_for_modeling_flag = 1 excludes spike/outlier months.
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
     AND t.include_for_modeling_flag = 1               -- Fix 21: exclude spike/outlier months
    JOIN pf_lookup pf
      ON t.groupby_key = pf.groupby_key
    WHERE pf.cust_prod_category IN ('APOLLO', 'BX', 'GLP-1', 'MPB Specialty', 'MPB Plasma')
),
-- ── Fix 12 step 2: resolve last_step_direction without LAST_VALUE IGNORE NULLS ─
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
-- ── typical_increase_month ────────────────────────────────────────────────
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
-- Includes typical_increase_month_step_up_pct and _count (backported from BT).
step_history AS (
    SELECT
        sh.groupby_key,
        SUM(CASE WHEN sh.cp_mom_pct_change >  0.02 THEN 1 ELSE 0 END)
                                                        AS step_up_count,
        AVG(CASE WHEN sh.cp_mom_pct_change >  0.02
                 THEN sh.cp_mom_pct_change END)         AS avg_step_up_pct,
        SUM(CASE WHEN sh.cp_mom_pct_change < -0.02 THEN 1 ELSE 0 END)
                                                        AS step_down_count,
        AVG(CASE WHEN sh.cp_mom_pct_change < -0.02
                 THEN sh.cp_mom_pct_change END)         AS avg_step_down_pct,
        MAX(sh.last_step_direction)                     AS last_step_direction,
        AVG(sh.recent_wac_mom_change_if_in_window)      AS recent_wac_avg_mom_change,
        AVG(CASE
            WHEN sh.cp_mom_pct_change > 0.02
             AND sh.price_month = tim.typical_increase_month
            THEN sh.cp_mom_pct_change
        END)                                            AS typical_increase_month_step_up_pct,
        SUM(CASE
            WHEN sh.cp_mom_pct_change > 0.02
             AND sh.price_month = tim.typical_increase_month
            THEN 1 ELSE 0
        END)                                            AS typical_increase_month_step_up_count
    FROM combined_mom sh
    LEFT JOIN typical_increase_month tim
      ON sh.groupby_key = tim.groupby_key
    WHERE sh.cust_prod_category IN ('APOLLO', 'BX')
    GROUP BY sh.groupby_key
),
assembled AS (
    SELECT
        a.groupby_key,
        -- acct_classification: do NOT COALESCE to UNKNOWN — NULL must stay NULL
        -- so that IN ('340B-CP','340B-CE') and = 'WAC' checks fail correctly
        -- for keys where modeling_base has no acct_classification.
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
        td.yoy_pairs_used_filtered,                     -- Fix 23: forwarded
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
        sh.recent_wac_avg_mom_change,
        sh.typical_increase_month_step_up_pct,
        sh.typical_increase_month_step_up_count
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
            -- Fix 24: explicit NULL anchor guard must come first.
            -- Without this, ABS(NULL / NULLIF(...) - 1) > 0.20 evaluates
            -- to UNKNOWN under ANSI three-valued logic and falls through
            -- to ELSE 1, incorrectly marking the key sign_only_eligible.
            WHEN a.anchor_contract_price IS NULL                               THEN 0
            WHEN COALESCE(a.yoy_pairs_used, 0) < 2                            THEN 0
            WHEN COALESCE(a.directional_consistency, 0) < 0.60                THEN 0
            WHEN a.recent_6m_avg_contract_price IS NULL
              OR a.recent_6m_avg_contract_price = 0                           THEN 0
            WHEN ABS(a.anchor_contract_price
                / NULLIF(a.recent_6m_avg_contract_price, 0) - 1) > 0.20       THEN 0
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
        CASE
            WHEN a.cust_prod_category = 'APOLLO'
            THEN
                CASE
                    WHEN COALESCE(a.step_up_count, 0) >= 2
                     AND a.last_step_direction = 'UP'
                     AND a.typical_increase_month = MONTH(a.anchor_month)
                     AND COALESCE(a.avg_yoy_pct, 0) >= 0
                     AND COALESCE(a.directional_consistency, 0) >= 0.60
                    THEN a.anchor_contract_price * (1 +
                            CASE
                                WHEN a.typical_increase_month_step_up_pct IS NOT NULL
                                 AND a.typical_increase_month_step_up_pct > a.avg_step_up_pct
                                 AND a.typical_increase_month_step_up_count >= 2
                                 AND a.product_family != 'LUPRON DEPOT'
                                THEN a.typical_increase_month_step_up_pct
                                ELSE a.avg_step_up_pct
                            END)
                    WHEN a.post_anchor_avg_contract_price IS NOT NULL
                     AND a.post_anchor_avg_contract_price > 0
                     AND a.anchor_contract_price IS NOT NULL
                     AND a.anchor_contract_price > 0
                     AND a.post_anchor_avg_contract_price
                         / NULLIF(a.anchor_contract_price, 0) BETWEEN 1.03 AND 2.0
                     AND a.post_anchor_cp_months >= 2
                    THEN a.post_anchor_avg_contract_price
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
             AND a.post_anchor_cp_months >= 2
            THEN a.post_anchor_avg_contract_price
            WHEN a.acct_classification != 'WAC'
             AND a.cust_prod_category  != 'APOLLO'
             AND a.post_anchor_avg_contract_price IS NOT NULL
             AND a.post_anchor_avg_contract_price  > 0
             AND a.recent_6m_avg_contract_price   IS NOT NULL
             AND a.recent_6m_avg_contract_price    > 0
             AND (a.post_anchor_avg_contract_price
                  / NULLIF(a.recent_6m_avg_contract_price, 0)) < 0.80
             AND a.post_anchor_cp_months >= 2
            THEN a.post_anchor_avg_contract_price
            WHEN a.acct_classification = 'WAC'
             AND a.post_anchor_avg_wac_spread IS NOT NULL
             AND a.anchor_wac_spread IS NOT NULL
             AND (a.post_anchor_avg_wac_spread - a.anchor_wac_spread) < -0.05
             AND a.post_anchor_months >= 2
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
capped AS (
    SELECT
        g.*,
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
    g.acct_classification,
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
    g.yoy_pairs_used_filtered,                              -- Fix 23: added to output
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
    g.typical_increase_month_step_up_pct,
    g.typical_increase_month_step_up_count,
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
                WHEN COALESCE(g.step_up_count, 0) >= 2
                 AND g.last_step_direction = 'UP'
                 AND g.typical_increase_month = MONTH(g.anchor_month)
                 AND COALESCE(g.avg_yoy_pct, 0) >= 0
                 AND COALESCE(g.directional_consistency, 0) >= 0.60
                THEN
                    CASE
                        WHEN g.typical_increase_month_step_up_pct IS NOT NULL
                         AND g.typical_increase_month_step_up_pct > g.avg_step_up_pct
                         AND g.typical_increase_month_step_up_count >= 2
                         AND g.product_family != 'LUPRON DEPOT'
                        THEN 'APOLLO_PROJECTED_STEP_UP_TYPICAL_MONTH_RATE'
                        ELSE 'APOLLO_PROJECTED_STEP_UP'
                    END
                WHEN g.post_anchor_avg_contract_price IS NOT NULL
                 AND g.post_anchor_avg_contract_price > 0
                 AND g.anchor_contract_price IS NOT NULL
                 AND g.anchor_contract_price > 0
                 AND g.post_anchor_avg_contract_price
                     / NULLIF(g.anchor_contract_price, 0) BETWEEN 1.03 AND 2.0
                 AND g.post_anchor_cp_months >= 2
                THEN 'APOLLO_POST_ANCHOR_PRICE_INCREASE_CORRECTION'
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
         AND g.post_anchor_cp_months >= 2
        THEN 'POST_ANCHOR_PRICE_INCREASE_CORRECTION'
        WHEN g.acct_classification != 'WAC'
         AND g.cust_prod_category  != 'APOLLO'
         AND g.post_anchor_avg_contract_price IS NOT NULL
         AND g.post_anchor_avg_contract_price  > 0
         AND g.recent_6m_avg_contract_price   IS NOT NULL
         AND g.recent_6m_avg_contract_price    > 0
         AND (g.post_anchor_avg_contract_price
              / NULLIF(g.recent_6m_avg_contract_price, 0)) < 0.80
         AND g.post_anchor_cp_months >= 2
        THEN 'POST_ANCHOR_PRICE_DROP_CORRECTION'
        WHEN g.acct_classification = 'WAC'
         AND g.post_anchor_avg_wac_spread IS NOT NULL
         AND g.anchor_wac_spread IS NOT NULL
         AND (g.post_anchor_avg_wac_spread - g.anchor_wac_spread) < -0.05
         AND g.post_anchor_months >= 2
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
    g.forecast_start_contract_price,
    g.forecast_start_price_capped_flag,
    -- ── expected_monthly_trend_pct ─────────────────────────────────────────
    CASE
        -- ── APOLLO: ±15% cap ──────────────────────────────────────────────
        WHEN g.cust_prod_category = 'APOLLO'
        THEN GREATEST(-0.15, LEAST(0.15,
            CASE
                WHEN COALESCE(g.step_up_count, 0) >= 2
                 AND g.last_step_direction = 'UP'
                 AND COALESCE(g.avg_yoy_pct, 0) >= 0
                 AND COALESCE(g.directional_consistency, 0) >= 0.60
                THEN
                    CASE
                        WHEN g.typical_increase_month_step_up_pct IS NOT NULL
                         AND g.typical_increase_month_step_up_pct > g.avg_step_up_pct
                         AND g.typical_increase_month_step_up_count >= 2
                         AND g.product_family != 'LUPRON DEPOT'
                        THEN g.typical_increase_month_step_up_pct
                        ELSE g.avg_step_up_pct
                    END
                -- Fix 23: gate on yoy_pairs_used_filtered (pairs that passed
                -- the ABS <= 5.0 filter) instead of yoy_pairs_used.
                -- Prevents NULL avg_yoy_pct propagating into GREATEST/LEAST.
                -- COALESCE(avg_yoy_pct, 0.0) is a final safety net.
                WHEN COALESCE(g.yoy_pairs_used_filtered, 0) >= 1
                THEN COALESCE(g.avg_yoy_pct, 0.0)
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2
                THEN COALESCE(g.pf_avg_yoy_pct, 0.0)
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2
                THEN COALESCE(g.mfr_avg_yoy_pct, 0.0)
                ELSE 0.0
            END))
        -- ── MPB Specialty: ±15% cap ───────────────────────────────────────
        WHEN g.cust_prod_category = 'MPB Specialty'
        THEN GREATEST(-0.15, LEAST(0.15,
            CASE
                WHEN g.acct_classification IN ('340B-CP','340B-CE')
                THEN CASE
                    WHEN COALESCE(g.regression_quarters_used, 0) >= 3
                     AND COALESCE(g.directional_consistency, 0) >= 0.60
                     AND ABS(g.raw_regression_trend_pct) <= 0.15
                    THEN g.raw_regression_trend_pct
                    ELSE 0.0
                END
                -- Fix 23: gate on yoy_pairs_used_filtered for MPB Specialty too
                WHEN COALESCE(g.yoy_pairs_used_filtered, 0) >= 1
                THEN COALESCE(g.avg_yoy_pct, 0.0)
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2
                THEN COALESCE(g.pf_avg_yoy_pct, 0.0)
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2
                THEN COALESCE(g.mfr_avg_yoy_pct, 0.0)
                ELSE 0.0
            END))
        -- ── BX non-340B: ±15% cap ─────────────────────────────────────────
        -- Fix 25: Dead GX branches removed. cust_prod_category is mutually
        -- exclusive — BX can never be GX. Removed:
        --   AND g.cust_prod_category != 'GX' guard on full-rate WHEN
        --   AND g.cust_prod_category = 'GX' THEN 0.01 branch
        --   AND g.cust_prod_category = 'GX' THEN -0.01 branch
        -- Full rate now fires when dc=1.0 AND avg_yoy_pct > 0, period.
        -- Dampened 0.19x applies to all other meaningful-trend keys.
        -- Negative trend dampened rate applies unconditionally for BX.
        WHEN g.cust_prod_category = 'BX'
         AND g.acct_classification NOT IN ('340B-CP','340B-CE')
        THEN GREATEST(-0.15, LEAST(0.15,
            CASE
                WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
                THEN
                    CASE
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
                              -- Full rate: all YOY pairs agree (dc=1.0),
                              -- trend meaningful and positive.
                              -- Fix 25: removed AND g.cust_prod_category != 'GX'
                              -- guard — BX is never GX so guard was always true.
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.directional_consistency = 1.0
                               AND g.avg_yoy_pct > 0
                              THEN g.avg_yoy_pct
                              -- Dampened rate for directionally consistent
                              -- but not perfectly uniform keys.
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
                        -- Fix 25: removed WHEN g.cust_prod_category = 'GX' THEN -0.01
                        -- branch — BX is never GX. Dampened rate applies to all BX.
                        WHEN g.avg_yoy_pct <= 0
                         AND g.directional_consistency >= 0.80
                        THEN g.avg_yoy_pct * 0.19
                        ELSE 0.0
                    END
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
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.directional_consistency = 1.0
                               AND g.avg_yoy_pct > 0
                              THEN g.avg_yoy_pct
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
                        THEN g.avg_yoy_pct * 0.19
                        ELSE 0.0
                    END
                ELSE 0.0
            END))
        -- ── All other segments: ±2% cap ───────────────────────────────────
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
                        WHEN g.g5_recent_price_not_falling = 1
                         AND g.directional_consistency >= 0.80
                        THEN CASE
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.directional_consistency = 1.0
                               AND g.avg_yoy_pct > 0
                               AND g.cust_prod_category != 'GX'
                              THEN g.avg_yoy_pct
                              WHEN ABS(g.avg_yoy_pct) > 0.03
                               AND g.avg_yoy_pct > 0
                               AND g.cust_prod_category = 'GX'
                              THEN 0.01
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
                            WHEN g.cust_prod_category = 'GX' THEN -0.01
                            ELSE g.avg_yoy_pct * 0.19
                        END
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
                 AND COALESCE(g.directional_consistency, 0) >= 0.60
                THEN
                    CASE
                        WHEN g.typical_increase_month_step_up_pct IS NOT NULL
                         AND g.typical_increase_month_step_up_pct > g.avg_step_up_pct
                         AND g.typical_increase_month_step_up_count >= 2
                         AND g.product_family != 'LUPRON DEPOT'
                        THEN 'STEP_UP_HISTORY_TYPICAL_MONTH'
                        ELSE 'STEP_UP_HISTORY'
                    END
                -- Fix 23: gate on yoy_pairs_used_filtered
                WHEN COALESCE(g.yoy_pairs_used_filtered, 0) >= 1 THEN 'AVG_YOY'
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2       THEN 'PF_AVG_YOY'
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2      THEN 'MFR_AVG_YOY'
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
                WHEN g.acct_classification IN ('340B-CP','340B-CE') THEN 'REGRESSION'
                -- Fix 23: gate on yoy_pairs_used_filtered
                WHEN COALESCE(g.yoy_pairs_used_filtered, 0) >= 1  THEN 'AVG_YOY'
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2        THEN 'PF_AVG_YOY'
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2       THEN 'MFR_AVG_YOY'
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
                WHEN g.g5_recent_price_not_falling = 1
                 AND g.directional_consistency >= 0.80
                THEN CASE
                         WHEN g.cust_prod_category = 'GX'   THEN 'SIGN_ONLY_025PCT'
                         WHEN ABS(g.avg_yoy_pct) > 0.03     THEN 'AVG_YOY_PROMOTED'
                         ELSE 'SIGN_ONLY_025PCT'
                     END
                WHEN g.g5_recent_price_not_falling = 1
                THEN 'SIGN_ONLY_025PCT'
                WHEN g.avg_yoy_pct <= 0
                 AND g.directional_consistency >= 0.80
                THEN CASE
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

-- Q1: Keys switching from NO_TREND to fallback method
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key) AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('PF_AVG_YOY','MFR_AVG_YOY')
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category, assigned_trend_method;

-- Q2: Bias check
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key)                             AS key_count,
    ROUND(AVG(expected_monthly_trend_pct) * 100, 3)        AS avg_trend_pct,
    ROUND(AVG(avg_yoy_pct) * 100, 3)                       AS avg_raw_yoy_pct
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category, assigned_trend_method;

-- Q3: Confirm no key-level trend overridden by fallback
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN ('PF_AVG_YOY','MFR_AVG_YOY')
  AND COALESCE(yoy_pairs_used, 0) >= 2;

-- Q4: PF/MFR variance vs key-level
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

-- Q5: Step history coverage
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key) AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN (
    'STEP_UP_HISTORY','STEP_UP_HISTORY_TYPICAL_MONTH','STEP_DOWN_HISTORY'
)
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category;

-- Q6: Step magnitude sanity
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(DISTINCT groupby_key)                             AS key_count,
    ROUND(AVG(expected_monthly_trend_pct) * 100, 2)        AS avg_trend_pct,
    ROUND(PERCENTILE(expected_monthly_trend_pct, 0.5) * 100, 2) AS p50_trend_pct,
    ROUND(MIN(expected_monthly_trend_pct) * 100, 2)        AS min_trend_pct,
    ROUND(MAX(expected_monthly_trend_pct) * 100, 2)        AS max_trend_pct
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE assigned_trend_method IN (
    'STEP_UP_HISTORY','STEP_UP_HISTORY_TYPICAL_MONTH','STEP_DOWN_HISTORY'
)
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category, assigned_trend_method;

-- Q7: Cap lift validation
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

-- Q8: acct_classification population check
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN acct_classification IS NULL     THEN 1 ELSE 0 END) AS null_acct_class,
    SUM(CASE WHEN acct_classification = 'UNKNOWN' THEN 1 ELSE 0 END) AS unknown_acct_class
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23;

-- Q13: Fix 23 validation — confirm no NULL expected_monthly_trend_pct
-- for APOLLO or MPB Specialty keys. Zero rows expected after fix.
SELECT
    cust_prod_category,
    assigned_trend_method,
    COUNT(*) AS null_trend_rows
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE cust_prod_category IN ('APOLLO','MPB Specialty')
  AND expected_monthly_trend_pct IS NULL
GROUP BY cust_prod_category, assigned_trend_method
ORDER BY cust_prod_category;

-- Q14: Fix 23 validation — confirm yoy_pairs_used vs yoy_pairs_used_filtered
-- divergence. Keys with yoy_pairs_used > yoy_pairs_used_filtered had extreme
-- pairs filtered. Before fix these could have fired AVG_YOY with NULL rate.
SELECT
    cust_prod_category,
    COUNT(DISTINCT groupby_key)                             AS key_count,
    SUM(CASE WHEN yoy_pairs_used > yoy_pairs_used_filtered THEN 1 ELSE 0 END)
                                                            AS keys_with_extreme_pairs,
    SUM(CASE WHEN yoy_pairs_used > 0
              AND yoy_pairs_used_filtered = 0 THEN 1 ELSE 0 END)
                                                            AS keys_all_pairs_extreme
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE cust_prod_category IN ('APOLLO','MPB Specialty','BX')
GROUP BY cust_prod_category
ORDER BY cust_prod_category;

-- Q15: Fix 24 validation — confirm no keys with NULL anchor are sign_only_eligible.
-- Zero rows expected after fix.
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_material_live_assumptions_v23
WHERE anchor_contract_price IS NULL
  AND sign_only_eligible = 1;