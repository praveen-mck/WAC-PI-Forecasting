-- =========================================================
-- STEP 4 (BT): CONTRACT PRICE BT MATERIAL ASSUMPTIONS v23
--
-- Point-in-time backtest version of Step 4.
-- Produces one row per run_id + groupby_key.
-- All signals capped at jump_off_month per BT run.
--
-- Leakage fixes:
--   L1 — Training data capped at history_end_dt per run.
--        anchor_month, recent_6m, prior_6m, trend, and guardrails
--        only see data available at forecast generation time.
--   L2 — sap_months recomputed from capped training data.
--        Live training clean inherits sap_months from full history,
--        inflating GX outlier thresholds and trend eligibility.
--   L3 — post_anchor_wac capped at jump_off_month.
--        Prevents WAC spread compression firing on future decreases.
--   L4 — post_anchor_contract_price capped at jump_off_month.
--        Prevents Branch 2 (drop) and Branch 2B (increase) firing
--        on price changes that hadn't happened at forecast time.
--        Root cause of BT_2025_01 ELIQUIS $345 vs $606 issue.
--
-- v28 changes vs v27:
--   APOLLO trend (v24) — replaced flat NO_TREND with AVG_YOY ±2%.
--   340B-CP ordering fix (v25) — category checks fire before
--   acct_classification in trend CASE blocks.
--   MPB Plasma fix (v26): MPB Plasma -> REGRESSION.
--   340B-CE ordering fix (v27): extended 340B-CP guard to 340B-CE.
--
--   Insulin regression overrides + AVG_YOY_PROMOTED demotion (v28):
--   product_family added to assembled CTE via join to
--   contract_price_modeling_base_v23 (one distinct value per
--   groupby_key). Uses modeling_base not training_clean to stay
--   consistent with leakage-control patterns in the rest of the query.
--   Enables two improvements identified in BX analysis:
--
--   (a) Insulin regression overrides:
--   8 high-volume BX insulin families strongly prefer REGRESSION
--   over SIGN_ONLY_025PCT (9-12% APE improvement, 100k-1M rows each).
--   Families: HUMALOG, NOVOLOG, LANTUS, NOVOLOG FLEXPEN,
--   HUMALOG KWIKPEN U-100, NOVOLOG MIX 70-30 FLEXPEN,
--   HUMALOG MIX 75-25 KWIKPEN, LANTUS SOLOSTAR.
--   Check fires after category-level overrides and before
--   340B-CP/CE acct_classification check.
--
--   (b) AVG_YOY_PROMOTED demotion tightening:
--   BX4 showed sign_only beats AVG_YOY_PROMOTED for 79% of
--   families (131/165). Promotion now requires directional_consistency
--   >= 0.80 (was implied by sign_only_eligible >= 0.60) to filter
--   out families where YOY trend is not reliably directional.
--   Families where AVG_YOY_PROMOTED genuinely wins (XARELTO,
--   ELIQUIS, JANUVIA, LANTUS) have high directional consistency
--   and will still promote correctly.
--
--   (c) Sparse-key AVG_YOY fallback — product_family and manufacturer:
--   Keys with yoy_pairs_used < 2 previously fell through to NO_TREND,
--   losing all trend signal. For APOLLO, MPB Specialty, MPB Plasma,
--   and BX categories (non-GX, non-GLP-1) a hierarchical fallback
--   is now applied:
--     Key:         yoy_pairs_used >= 2  → key-level avg_yoy (existing)
--     PF:          key < 2, pf >= 2     → product_family avg_yoy
--     Mfr:         key < 2, pf < 2, mfr >= 2 → manufacturer avg_yoy
--     NO_TREND:    all three fail       → 0.0
--   GX and GLP-1 are excluded — GX trend logic depends on key-level
--   guardrails that aren't meaningful at aggregated levels.
--   All fallback trends capped at same ±2% as key-level.
--   New CTEs: pf_trend, mfr_trend.
--   pf_lookup extended to carry manufacturer_id.
--
-- v23 changes vs v28:
--   (a) PF/MFR fallback trend cap reverted to ±2% outer cap only.
--       Distribution analysis showed p50 PF trend = 1.2% and p50 MFR
--       trend = 6%, making a ±0.5% inner cap too aggressive — it would
--       clip the majority of signal. The step 8 exponent cap of 8
--       quarters (24 months max compounding) is sufficient to prevent
--       long-horizon explosion without destroying near-term signal.
--
--   (b) BX sparse fallback negative-only restriction:
--       PF_AVG_YOY and MFR_AVG_YOY fallback for BX sparse keys now
--       only applies when the pooled trend is negative (price declining).
--       Analysis showed 89% of BX PF_AVG_YOY keys had positive family
--       trends averaging +108% annual — driven by high-WAC branded drugs
--       contaminating the pooled family signal for low-price generics.
--       Negative trends are preserved as they produce $1.12B less error
--       than NO_TREND. Positive trends revert to NO_TREND.
--       Applies to both expected_monthly_trend_pct and assigned_trend_method.
--
--   (c) APOLLO + BX typical_increase_month detection:
--       New CTEs apollo_mom + typical_increase_month compute the calendar
--       month where each APOLLO and BX key most frequently has significant
--       price increases (>2% MoM) from capped training data. Stored in
--       output and passed through to step 8 via resolved assumptions.
--       Step 8 uses this to offset the annual compounding so the forecast
--       step fires at the correct horizon rather than always at month 12.
--       e.g. ENBREL increases in February: jump_off=Jan, offset=11,
--       FLOOR((1+11)/12)=1 → step fires at horizon 1 (Feb 2025) ✓.
--       BX branded drugs (XARELTO, ELIQUIS, JANUVIA etc.) follow the
--       same annual step-up pattern and benefit from the same offset.
--       Also applies to GLP-1 (69.4% increase in Jan), MPB Specialty
--       (27.7% Jan), and MPB Plasma (28% Jan).
--       GX, OTC, BIOSIMS, DROP SHIP, VAX excluded — no predictable
--       annual increase month pattern detected.
--       Keys with no detected increase month default to offset=0
--       (step fires at month 12 as before).
--
-- Bug fix: removed stray AND e.run_id = ma.run_id from bt_sap_coverage
--          (ma alias does not exist in this script).
--
-- Feeds: contract_price_bt_resolved_assumptions_v23
--
-- QA notes (see bottom of file):
--   Q1 — Count of keys switching from NO_TREND to a fallback method,
--        broken out by fallback tier and category.
--   Q2 — Bias check: compare pre/post fallback avg error against
--        eval detail actuals for switched keys.
--   Q3 — Confirm no previously-eligible key-level trend was overridden.
--   Q4 — Stability check: compare pf/mfr avg_yoy_pct variance vs
--        key-level avg_yoy_pct for switched keys.
-- =========================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_material_assumptions_v23 AS
WITH eligible AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_bt_run_eligibility_v23
    WHERE is_eligible_for_run = 1
),
-- L2: recompute sap_months from capped training data per run
bt_sap_coverage AS (
    SELECT
        e.run_id,
        b.groupby_key,
        COUNT(DISTINCT b.cal_month_start_dt)    AS sap_months_bt
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON e.groupby_key = b.groupby_key
     AND b.cal_month_start_dt <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
    GROUP BY e.run_id, b.groupby_key
),
-- L1: recent_6m and prior_6m capped at history_end_dt
recent_6m AS (
    SELECT
        e.run_id,
        e.groupby_key,
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
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23 la
      ON e.run_id = la.run_id AND e.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON e.groupby_key = b.groupby_key
     AND b.cal_month_start_dt <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
    GROUP BY e.run_id, e.groupby_key, la.anchor_month
),
-- L3: post-anchor WAC capped at jump_off_month
post_anchor_wac AS (
    SELECT
        e.run_id,
        b.groupby_key,
        AVG(b.wac_spread)                               AS post_anchor_avg_wac_spread,
        COUNT(DISTINCT b.cal_month_start_dt)            AS post_anchor_months
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23 la
      ON e.run_id = la.run_id AND e.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON e.groupby_key = b.groupby_key
     AND b.cal_month_start_dt >  la.anchor_month
     AND b.cal_month_start_dt <  e.jump_off_month       -- L3
     AND b.exclude_from_actuals_flag = 0
     AND b.wac_spread IS NOT NULL
    GROUP BY e.run_id, b.groupby_key
),
-- L4: post-anchor contract price capped at jump_off_month
post_anchor_cp AS (
    SELECT
        e.run_id,
        b.groupby_key,
        NULLIF(SUM(b.total_net_cos), 0)
            / NULLIF(SUM(b.total_sls_qty), 0)           AS post_anchor_avg_contract_price,
        COUNT(DISTINCT b.cal_month_start_dt)            AS post_anchor_cp_months
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23 la
      ON e.run_id = la.run_id AND e.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON e.groupby_key = b.groupby_key
     AND b.cal_month_start_dt >  la.anchor_month
     AND b.cal_month_start_dt <  e.jump_off_month       -- L4
     AND b.exclude_from_actuals_flag = 0
     AND b.total_net_cos IS NOT NULL
     AND b.total_sls_qty IS NOT NULL
    GROUP BY e.run_id, b.groupby_key
),
-- Yearly YoY trend from capped training data (key-level)
yearly_price AS (
    SELECT
        e.run_id,
        b.groupby_key,
        CEIL((DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) + 1) / 12.0) AS yr_bucket,
        NULLIF(SUM(b.total_net_cos), 0) / NULLIF(SUM(b.total_sls_qty), 0)          AS yr_price
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23 la
      ON e.run_id = la.run_id AND e.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON e.groupby_key = b.groupby_key
     AND b.cal_month_start_dt <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
     AND DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) BETWEEN 0 AND 47
    GROUP BY e.run_id, b.groupby_key,
             CEIL((DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) + 1) / 12.0)
),
yearly_yoy AS (
    SELECT
        y_curr.run_id,
        y_curr.groupby_key,
        (y_curr.yr_price / NULLIF(y_prev.yr_price, 0)) - 1     AS yoy_pct,
        CASE
            WHEN (y_curr.yr_price / NULLIF(y_prev.yr_price, 0)) - 1 > 0
            THEN 1 ELSE 0
        END                                                     AS is_positive
    FROM yearly_price y_curr
    JOIN yearly_price y_prev
      ON y_curr.run_id       = y_prev.run_id
     AND y_curr.groupby_key  = y_prev.groupby_key
     AND y_curr.yr_bucket    = y_prev.yr_bucket - 1
    WHERE y_curr.yr_price IS NOT NULL
      AND y_prev.yr_price  IS NOT NULL
),
trend_direction AS (
    SELECT
        run_id,
        groupby_key,
        COUNT(*)                                        AS yoy_pairs_used,
        AVG(yoy_pct)                                    AS avg_yoy_pct,
        AVG(CAST(is_positive AS FLOAT))                 AS pct_positive_pairs,
        GREATEST(
            AVG(CAST(is_positive AS FLOAT)),
            1 - AVG(CAST(is_positive AS FLOAT))
        )                                               AS directional_consistency
    FROM yearly_yoy
    GROUP BY run_id, groupby_key
),
-- OLS regression from capped training data
-- Window function computed in subquery to avoid window-inside-aggregate error
quarterly_price AS (
    SELECT
        e.run_id,
        b.groupby_key,
        CEIL((DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) + 1) / 3.0) AS qtr_bucket,
        NULLIF(SUM(b.total_net_cos), 0) / NULLIF(SUM(b.total_sls_qty), 0)         AS qtr_price
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23 la
      ON e.run_id = la.run_id AND e.groupby_key = la.groupby_key
    JOIN uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 b
      ON e.groupby_key = b.groupby_key
     AND b.cal_month_start_dt <= e.history_end_dt
     AND b.exclude_from_training_flag = 0
     AND DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) BETWEEN 0 AND 23
    GROUP BY e.run_id, b.groupby_key,
             CEIL((DATEDIFF(MONTH, b.cal_month_start_dt, la.anchor_month) + 1) / 3.0)
),
quarterly_with_x AS (
    SELECT
        run_id,
        groupby_key,
        qtr_price,
        MAX(qtr_bucket) OVER (PARTITION BY run_id, groupby_key) - qtr_bucket AS x
    FROM quarterly_price
    WHERE qtr_price IS NOT NULL
),
trend_regression AS (
    SELECT
        run_id,
        groupby_key,
        COUNT(*)                                            AS quarters_used,
        (COUNT(*) * SUM(x * qtr_price) - SUM(x) * SUM(qtr_price))
        / NULLIF(
            COUNT(*) * SUM(x * x) - SUM(x) * SUM(x),
          0)                                               AS ols_slope,
        AVG(qtr_price)                                     AS avg_price_ref
    FROM quarterly_with_x
    GROUP BY run_id, groupby_key
),
-- v28: one product_family + manufacturer_id + cust_prod_category +
-- acct_classification per groupby_key from modeling_base.
-- All four fields are static per groupby_key so no date cap needed.
-- cust_prod_category and acct_classification sourced here because they
-- are not guaranteed to exist on the eligibility table.
-- Uses modeling_base (not training_clean) to stay consistent with
-- leakage-control patterns in the rest of the query.
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
-- ── Fallback trend tier 1: product_family level ────────────────────────────
-- Aggregates yearly_yoy rows across all groupby_keys that share the same
-- product_family, per run_id. Used when a key has yoy_pairs_used < 2.
-- Scope: APOLLO, MPB Specialty, MPB Plasma, BX (non-GX, non-GLP-1).
-- GX excluded — its trend guardrails (sign_only_eligible, wac_spread_ok,
-- g5_recent_price_not_falling) are key-level and not meaningful when pooled.
pf_trend AS (
    SELECT
        yy.run_id,
        pf.product_family,
        COUNT(*)                                        AS pf_yoy_pairs_used,
        AVG(yy.yoy_pct)                                 AS pf_avg_yoy_pct
    FROM yearly_yoy yy
    JOIN pf_lookup pf ON yy.groupby_key = pf.groupby_key
    WHERE pf.product_family IS NOT NULL
    GROUP BY yy.run_id, pf.product_family
),
-- ── Fallback trend tier 2: manufacturer level ──────────────────────────────
-- Aggregates yearly_yoy rows across all groupby_keys sharing manufacturer_id,
-- per run_id. Used when both key and product_family have yoy_pairs_used < 2.
mfr_trend AS (
    SELECT
        yy.run_id,
        pf.manufacturer_id,
        COUNT(*)                                        AS mfr_yoy_pairs_used,
        AVG(yy.yoy_pct)                                 AS mfr_avg_yoy_pct
    FROM yearly_yoy yy
    JOIN pf_lookup pf ON yy.groupby_key = pf.groupby_key
    WHERE pf.manufacturer_id IS NOT NULL
    GROUP BY yy.run_id, pf.manufacturer_id
),
-- ── APOLLO typical price increase month ──────────────────────────────────
-- Pre-computes MoM contract price changes for APOLLO, BX, GLP-1,
-- MPB Specialty, and MPB Plasma keys from capped training data.
-- GX, OTC, BIOSIMS, DROP SHIP, VAX excluded — their increase months
-- are evenly distributed with no predictable annual pattern.
-- GLP-1: 69.4% of keys increase in January — strongest signal.
-- APOLLO/BX: clustered in Jan/Feb. MPB: clustered in Jan.
-- Capped at history_end_dt per run to prevent leakage.
apollo_mom AS (
    SELECT
        e.run_id,
        t.groupby_key,
        t.cal_month_start_dt,
        MONTH(t.cal_month_start_dt)                     AS price_month,
        t.contract_price
            / NULLIF(LAG(t.contract_price) OVER (
                PARTITION BY e.run_id, t.groupby_key
                ORDER BY t.cal_month_start_dt
            ), 0) - 1                                   AS mom_pct_change
    FROM eligible e
    JOIN uspd_analytics_den.analytics_gold.contract_price_training_clean_v23 t
      ON e.groupby_key = t.groupby_key
     AND t.cal_month_start_dt <= e.history_end_dt
    JOIN pf_lookup pf
      ON t.groupby_key = pf.groupby_key
    WHERE pf.cust_prod_category IN ('APOLLO', 'BX', 'GLP-1', 'MPB Specialty', 'MPB Plasma')
),
typical_increase_month AS (
    SELECT
        run_id,
        groupby_key,
        price_month                                     AS typical_increase_month
    FROM (
        SELECT
            run_id,
            groupby_key,
            price_month,
            COUNT(*)                                    AS increase_count,
            AVG(mom_pct_change)                         AS avg_increase
        FROM apollo_mom
        WHERE mom_pct_change > 0.02
        GROUP BY run_id, groupby_key, price_month
    )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY run_id, groupby_key
        ORDER BY increase_count DESC, avg_increase DESC
    ) = 1
),
assembled AS (
    SELECT
        e.run_id,
        e.groupby_key,
        COALESCE(pf.acct_classification, 'UNKNOWN')     AS acct_classification,
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
        -- Key-level trend signals
        td.yoy_pairs_used,
        td.avg_yoy_pct,
        td.directional_consistency,
        COALESCE(tr.ols_slope / NULLIF(tr.avg_price_ref, 0), 0) AS raw_regression_trend_pct,
        -- Product-family fallback trend signals
        pft.pf_yoy_pairs_used,
        pft.pf_avg_yoy_pct,
        -- Manufacturer fallback trend signals
        mft.mfr_yoy_pairs_used,
        mft.mfr_avg_yoy_pct,
        -- APOLLO typical increase month (NULL for non-APOLLO keys)
        tim.typical_increase_month
    FROM eligible e
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23   la   ON e.run_id = la.run_id   AND e.groupby_key = la.groupby_key
    LEFT JOIN bt_sap_coverage                                                         sc   ON e.run_id = sc.run_id   AND e.groupby_key = sc.groupby_key
    LEFT JOIN recent_6m                                                               r6   ON e.run_id = r6.run_id   AND e.groupby_key = r6.groupby_key
    LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_bt_latest_obs_v23     lo   ON e.run_id = lo.run_id   AND e.groupby_key = lo.groupby_key
    LEFT JOIN post_anchor_wac                                                         paw  ON e.run_id = paw.run_id  AND e.groupby_key = paw.groupby_key
    LEFT JOIN post_anchor_cp                                                          pacp ON e.run_id = pacp.run_id AND e.groupby_key = pacp.groupby_key
    LEFT JOIN trend_direction                                                          td   ON e.run_id = td.run_id   AND e.groupby_key = td.groupby_key
    LEFT JOIN trend_regression                                                         tr   ON e.run_id = tr.run_id   AND e.groupby_key = tr.groupby_key
    LEFT JOIN pf_lookup                                                                pf   ON e.groupby_key = pf.groupby_key
    LEFT JOIN pf_trend                                                                 pft  ON e.run_id = pft.run_id  AND COALESCE(pf.product_family, 'UNKNOWN') = pft.product_family
    LEFT JOIN mfr_trend                                                                mft  ON e.run_id = mft.run_id  AND pf.manufacturer_id = mft.manufacturer_id
    LEFT JOIN typical_increase_month                                                   tim  ON e.run_id = tim.run_id  AND e.groupby_key = tim.groupby_key
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
        END                                                 AS wac_spread_ok
    FROM assembled a
)
SELECT
    g.run_id,
    g.groupby_key,
    g.cust_prod_category,
    g.acct_classification,
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
    -- Fallback diagnostics — useful for QA and future tuning
    g.pf_yoy_pairs_used,
    g.pf_avg_yoy_pct,
    g.mfr_yoy_pairs_used,
    g.mfr_avg_yoy_pct,
    g.sign_only_eligible,
    g.g5_recent_price_not_falling,
    g.typical_increase_month,
    -- ── forecast_start_contract_price ──────────────────────────────────────
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
                THEN g.post_anchor_avg_contract_price
                ELSE g.anchor_contract_price
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
        THEN g.post_anchor_avg_contract_price
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
        THEN g.post_anchor_avg_contract_price
        WHEN g.acct_classification = 'WAC'
         AND g.post_anchor_avg_wac_spread IS NOT NULL
         AND g.anchor_wac_spread IS NOT NULL
         AND (g.post_anchor_avg_wac_spread - g.anchor_wac_spread) < -0.05
         AND (   g.post_anchor_months >= 3
              OR (g.post_anchor_avg_wac_spread - g.anchor_wac_spread) < -0.15)
        THEN
            GREATEST(
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
                    THEN g.recent_6m_avg_contract_price
                    WHEN g.latest_6_observed_months >= 3
                    THEN g.latest_6_observed_avg_contract_price
                    ELSE g.anchor_contract_price
                END
                * (1 + (g.post_anchor_avg_wac_spread - g.anchor_wac_spread)),
            0)
        ELSE
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
                THEN g.recent_6m_avg_contract_price
                WHEN g.latest_6_observed_months >= 3
                THEN g.latest_6_observed_avg_contract_price
                ELSE g.anchor_contract_price
            END
    END                                                     AS forecast_start_contract_price,
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
    -- ── expected_monthly_trend_pct ─────────────────────────────────────────
    -- v24: APOLLO uses avg_yoy_pct capped at ±2% annual rate (was 0.0).
    -- v28c: sparse-key fallback for APOLLO, MPB, BX — all tiers capped ±2%.
    -- v23: All non-340B categories pass full annual YOY rate — step 8 compounds
    --      annually for these categories (ROUND(horizon/12, 0), cap 2 years).
    --      340B-CP/CE retains quarterly compounding in step 8 and continues
    --      to use raw_regression_trend_pct (quarterly OLS slope) here.
    --      SIGN_ONLY rates converted: ±0.0025/qtr → ±0.01/yr.
    --      AVG_YOY_PROMOTED dampening: /4.0 removed, * 0.19 retained.
    GREATEST(-0.02, LEAST(0.02,
        CASE
            -- ── Category-level overrides (fire first) ──────────────────────
            WHEN g.cust_prod_category = 'APOLLO'
            THEN
                CASE
                    -- Step 8 compounds APOLLO annually (ROUND(horizon/12, 0)),
                    -- so expected_monthly_trend_pct carries the full annual rate.
                    -- avg_yoy_pct is already an annual rate — pass it through directly.
                    WHEN COALESCE(g.yoy_pairs_used, 0) >= 1
                    THEN g.avg_yoy_pct
                    WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2
                    THEN g.pf_avg_yoy_pct
                    WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2
                    THEN g.mfr_avg_yoy_pct
                    ELSE 0.0
                END
            WHEN g.cust_prod_category = 'GLP-1'         THEN g.raw_regression_trend_pct
            WHEN g.cust_prod_category = 'MPB Specialty'
            THEN
                CASE
                    -- Annual compounding in step 8 — pass full annual rate
                    WHEN COALESCE(g.yoy_pairs_used, 0) >= 1
                    THEN g.avg_yoy_pct
                    WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2
                    THEN g.pf_avg_yoy_pct
                    WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2
                    THEN g.mfr_avg_yoy_pct
                    ELSE 0.0
                END
            WHEN g.cust_prod_category = 'MPB Plasma'    THEN g.raw_regression_trend_pct
            -- ── v28a: insulin product-family regression overrides ──────────
            WHEN g.product_family IN (
                'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
                'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
                'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
            )                                            THEN g.raw_regression_trend_pct
            -- ── v25/v27: 340B-CP / 340B-CE regression ─────────────────────
            WHEN g.acct_classification IN ('340B-CP','340B-CE')
             AND g.cust_prod_category NOT IN ('APOLLO','GLP-1','MPB Specialty','MPB Plasma')
                                                         THEN g.raw_regression_trend_pct
            -- ── BX sign_only path (v28b: directional_consistency >= 0.80) ──
            WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
            THEN
                CASE
                    -- Annual compounding in step 8 — rates converted to annual
                    -- SIGN_ONLY: ±1% annual (was ±0.0025 quarterly × 4)
                    -- AVG_YOY_PROMOTED: full dampened annual rate (was /4.0)
                    WHEN g.g5_recent_price_not_falling = 1
                     AND g.directional_consistency >= 0.80
                    THEN CASE WHEN ABS(g.avg_yoy_pct) > 0.03 THEN g.avg_yoy_pct * 0.19
                              WHEN g.avg_yoy_pct > 0          THEN  0.01
                              WHEN g.avg_yoy_pct < 0          THEN -0.01
                              ELSE 0.0 END
                    WHEN g.g5_recent_price_not_falling = 1
                    THEN CASE WHEN g.avg_yoy_pct > 0 THEN  0.01
                              WHEN g.avg_yoy_pct < 0 THEN -0.01
                              ELSE 0.0 END
                    WHEN g.avg_yoy_pct <= 0
                     AND g.directional_consistency >= 0.80 THEN g.avg_yoy_pct * 0.19
                    ELSE 0.0
                END
            -- ── v28c/v23: sparse fallback for BX only ─────────────────────
            -- Only fires when yoy_pairs_used < 2. Keys with >= 2 pairs that
            -- failed sign_only_eligible guardrails stay at NO_TREND correctly.
            -- GX, BIOSIMS, OTC, VAX stay at NO_TREND.
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
                    -- v23: negative-only restriction — positive pooled trends
                    -- are unreliable for BX sparse keys (89% of PF_AVG_YOY keys
                    -- had positive family trends averaging +108% annual, driven
                    -- by high-WAC branded drugs contaminating the family pool).
                    -- Negative trends are preserved as they reliably signal
                    -- declining price series ($1.12B error reduction vs NO_TREND).
                    WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2
                     AND g.pf_avg_yoy_pct < 0
                    THEN g.pf_avg_yoy_pct          -- annual rate, step 8 compounds yearly
                    WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2
                     AND g.mfr_avg_yoy_pct < 0
                    THEN g.mfr_avg_yoy_pct          -- annual rate, step 8 compounds yearly
                    ELSE 0.0
                END
            ELSE 0.0
        END
    ))                                                      AS expected_monthly_trend_pct,
    -- ── assigned_trend_method ──────────────────────────────────────────────
    -- Unchanged from v28 — PF_AVG_YOY and MFR_AVG_YOY labels are retained;
    -- the v23 change only affects the magnitude, not the method assignment.
    CASE
        WHEN g.cust_prod_category = 'APOLLO'
        THEN
            CASE
                WHEN COALESCE(g.yoy_pairs_used, 0) >= 1    THEN 'AVG_YOY'
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2 THEN 'PF_AVG_YOY'
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2 THEN 'MFR_AVG_YOY'
                ELSE 'NO_TREND'
            END
        WHEN g.cust_prod_category = 'GLP-1'                THEN 'REGRESSION'
        WHEN g.cust_prod_category = 'MPB Specialty'
        THEN
            CASE
                WHEN COALESCE(g.yoy_pairs_used, 0) >= 1    THEN 'AVG_YOY'
                WHEN COALESCE(g.pf_yoy_pairs_used, 0) >= 2 THEN 'PF_AVG_YOY'
                WHEN COALESCE(g.mfr_yoy_pairs_used, 0) >= 2 THEN 'MFR_AVG_YOY'
                ELSE 'NO_TREND'
            END
        WHEN g.cust_prod_category = 'MPB Plasma'           THEN 'REGRESSION'
        WHEN g.product_family IN (
            'HUMALOG','NOVOLOG','LANTUS','NOVOLOG FLEXPEN',
            'HUMALOG KWIKPEN U-100','NOVOLOG MIX 70-30 FLEXPEN',
            'HUMALOG MIX 75-25 KWIKPEN','LANTUS SOLOSTAR'
        )                                                   THEN 'REGRESSION'
        WHEN g.acct_classification IN ('340B-CP','340B-CE')
         AND g.cust_prod_category NOT IN ('APOLLO','GLP-1','MPB Specialty','MPB Plasma')
                                                            THEN 'REGRESSION'
        WHEN g.sign_only_eligible = 1 AND g.wac_spread_ok = 1
        THEN
            CASE
                WHEN g.g5_recent_price_not_falling = 1
                 AND g.directional_consistency >= 0.80
                THEN CASE WHEN ABS(g.avg_yoy_pct) > 0.03 THEN 'AVG_YOY_PROMOTED'
                          ELSE 'SIGN_ONLY_025PCT' END
                WHEN g.g5_recent_price_not_falling = 1
                THEN 'SIGN_ONLY_025PCT'
                WHEN g.avg_yoy_pct <= 0
                 AND g.directional_consistency >= 0.80 THEN 'AVG_YOY_PROMOTED'
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
        WHEN g.latest_6_observed_months >= 6 THEN 'PRICE_6MO_AVG'
        WHEN g.latest_6_observed_months >= 3 THEN 'PRICE_3_TO_5_MO_AVG'
        WHEN g.latest_6_observed_months >= 1 THEN 'PRICE_LAST_OBSERVED'
        ELSE 'NO_PRICE_AVAILABLE'
    END                                                     AS sparse_price_confidence,
    CASE WHEN g.latest_6_observed_months < 6 THEN 1 ELSE 0 END AS is_sparse_price_flag
FROM guardrails g
;