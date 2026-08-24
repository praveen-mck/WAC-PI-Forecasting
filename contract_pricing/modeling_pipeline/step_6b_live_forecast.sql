

-- =====================================================================
-- STEP 7 (LIVE): FUTURE FORECAST MONTHS
-- Generates one row per groupby_key + forecast_horizon_month_num
-- for 60 months from jump_off_month.
-- Uses a sequence generator instead of joining to actual months
-- (no actual data exists for future months).
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_live_future_months_v23 AS
WITH month_sequence AS (
    -- Generate integers 1 through 60 for forecast horizons
    SELECT explode(sequence(1, 60)) AS forecast_horizon_month_num
)
SELECT
    ra.groupby_key,
    ra.jump_off_month,
    ms.forecast_horizon_month_num,
    ADD_MONTHS(ra.jump_off_month, ms.forecast_horizon_month_num)
                                                        AS forecast_month,
    DATE_FORMAT(
        ADD_MONTHS(ra.jump_off_month, ms.forecast_horizon_month_num),
        'yyyy-MM'
    )                                                   AS forecast_year_month
FROM uspd_analytics_den.analytics_gold.contract_price_live_resolved_assumptions_v23 ra
CROSS JOIN month_sequence ms
;


-- =====================================================================
-- STEP 8 (LIVE): FORECASTED CONTRACT PRICE
-- Identical compounding logic to BT Step 8.
-- No actual_contract_price — this is a pure forward forecast.
--
-- 340B-CP/CE (non-APOLLO, non-MPB Specialty): quarterly compounding
--   ROUND(horizon/3.0, 0), cap 8 quarters = 24 months.
--   APOLLO and MPB Specialty excluded — annual trend rates would
--   compound 8x quarterly instead of 2x annually.
--
-- All others: annual compounding with typical_increase_month offset.
--   FLOOR((horizon + offset)/12.0), cap 2 years.
-- =====================================================================
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_live_forecasted_v23 AS
SELECT
    ra.groupby_key,
    ra.jump_off_month,
    ra.acct_classification,
    ra.cust_prod_category,
    ra.product_family,
    ra.manufacturer_id,
    ra.sap_cust_num_trim,
    ra.mtrl_num,
    ra.cust_segment,
    ra.national_grp_id,
    ra.national_grp_desc,
    ra.common_grp_id,
    ra.common_grp_desc,
    ra.subset_l2_id_resolved,
    ra.mtrl_nme_nvgton,
    ra.ndc_num,
    ra.therapeutic_class,
    ra.manufacturer_name,
    ra.final_product_group,
    src.WAC,
    src.total_net_revenue,
    ra.top_100_brand_flag,
    ra.brand_wac_rank,
    ra.first_month,
    ra.anchor_month,
    ra.months_since_first_asof_jumpoff,
    ra.anchor_contract_price,
    ra.anchor_wac_weighted,
    ra.anchor_wac_spread,
    ra.anchor_total_sls_qty,
    ra.anchor_total_net_cos,
    ra.forecast_start_contract_price,
    ra.forecast_start_wac_spread,
    ra.forecast_start_price_source,
    ra.forecast_start_price_capped_flag,
    ra.sparse_price_confidence,
    ra.is_sparse_price_flag,
    ra.recent_6m_months,
    ra.latest_6_observed_months,
    ra.resolved_monthly_trend_pct,
    ra.trend_source,
    ra.trend_cap_applied,
    ra.typical_increase_month,
    ra.step_up_count,
    ra.avg_step_up_pct,
    ra.last_step_direction,
    ra.recent_wac_avg_mom_change,
    fam.forecast_month,
    fam.forecast_horizon_month_num,
    fam.forecast_year_month,
    -- ── Forecasted contract price ─────────────────────────────────────
    CASE
        WHEN ra.forecast_start_contract_price IS NULL THEN NULL
        -- 340B-CP / 340B-CE (non-APOLLO, non-MPB Specialty):
        -- quarterly compounding — trend rate is quarterly OLS slope.
        WHEN ra.acct_classification IN ('340B-CP', '340B-CE')
         AND ra.cust_prod_category NOT IN ('APOLLO', 'MPB Specialty')
        THEN GREATEST(
            ra.forecast_start_contract_price * POWER(
                1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                LEAST(ROUND(fam.forecast_horizon_month_num / 3.0, 0), 8)
            ), 0)
        -- All others: annual compounding with typical_increase_month offset.
        -- Offset shifts compounding to fire at the correct calendar month.
        ELSE GREATEST(
            ra.forecast_start_contract_price * POWER(
                1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                LEAST(
                    FLOOR(
                        (fam.forecast_horizon_month_num
                         + CASE
                             WHEN ra.typical_increase_month IS NULL
                             THEN 0
                             WHEN ra.typical_increase_month > MONTH(ra.jump_off_month)
                             THEN 12 - (ra.typical_increase_month - MONTH(ra.jump_off_month))
                             WHEN ra.typical_increase_month = MONTH(ra.jump_off_month)
                             THEN 0
                             ELSE 12 - (12 - MONTH(ra.jump_off_month) + ra.typical_increase_month)
                           END
                        ) / 12.0
                    ), 2)
            ), 0)
    END                                                 AS forecasted_contract_price,
    -- ── Implied WAC spread on forecasted price ────────────────────────
    -- Uses jump_off_month WAC (point-in-time, not MAX across history)
    CASE
        WHEN ra.WAC IS NOT NULL AND ra.WAC > 0
        THEN (
            CASE
                WHEN ra.forecast_start_contract_price IS NULL THEN NULL
                WHEN ra.acct_classification IN ('340B-CP', '340B-CE')
                 AND ra.cust_prod_category NOT IN ('APOLLO', 'MPB Specialty')
                THEN GREATEST(
                    ra.forecast_start_contract_price * POWER(
                        1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                        LEAST(ROUND(fam.forecast_horizon_month_num / 3.0, 0), 8)
                    ), 0)
                ELSE GREATEST(
                    ra.forecast_start_contract_price * POWER(
                        1 + COALESCE(ra.resolved_monthly_trend_pct, 0),
                        LEAST(
                            FLOOR(
                                (fam.forecast_horizon_month_num
                                 + CASE
                                     WHEN ra.typical_increase_month IS NULL THEN 0
                                     WHEN ra.typical_increase_month > MONTH(ra.jump_off_month)
                                     THEN 12 - (ra.typical_increase_month - MONTH(ra.jump_off_month))
                                     WHEN ra.typical_increase_month = MONTH(ra.jump_off_month) THEN 0
                                     ELSE 12 - (12 - MONTH(ra.jump_off_month) + ra.typical_increase_month)
                                   END
                                ) / 12.0
                            ), 2)
                    ), 0)
            END
        ) / ra.WAC - 1
        ELSE NULL
    END                                                 AS implied_forecast_wac_spread
FROM uspd_analytics_den.analytics_gold.contract_price_live_resolved_assumptions_v23 ra
JOIN uspd_analytics_den.analytics_gold.contract_price_live_future_months_v23 fam
  ON ra.groupby_key = fam.groupby_key
-- Point-in-time WAC at jump_off_month (not MAX across history)
LEFT JOIN (
    SELECT
        groupby_key,
        cal_month_start_dt,
        MAX(WAC_WEIGHTED)       AS WAC,
        MAX(TOTAL_NET_REVENUE)  AS total_net_revenue
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23
    GROUP BY groupby_key, cal_month_start_dt
) src
  ON  ra.groupby_key         = src.groupby_key
 AND  src.cal_month_start_dt = ra.jump_off_month
;


-- =====================================================================
-- QA QUERIES
-- =====================================================================

-- Q1: Row count and jump_off_month — confirm single jump-off date
SELECT
    jump_off_month,
    COUNT(DISTINCT groupby_key)                         AS key_count,
    COUNT(*)                                            AS total_rows
FROM uspd_analytics_den.analytics_gold.contract_price_live_forecasted_v23
GROUP BY jump_off_month;
-- Expect: one jump_off_month, key_count * 60 = total_rows

-- Q2: Trend method distribution
SELECT
    cust_prod_category,
    trend_source,
    trend_cap_applied,
    COUNT(DISTINCT groupby_key)                         AS key_count,
    ROUND(AVG(resolved_monthly_trend_pct) * 100, 3)    AS avg_trend_pct
FROM uspd_analytics_den.analytics_gold.contract_price_live_resolved_assumptions_v23
GROUP BY cust_prod_category, trend_source, trend_cap_applied
ORDER BY cust_prod_category, key_count DESC;

-- Q3: Forecast explosion check (compounding > 2x starting price)
SELECT
    cust_prod_category,
    trend_source,
    COUNT(*) AS explosion_rows,
    ROUND(AVG(forecasted_contract_price
              / NULLIF(forecast_start_contract_price, 0)), 3) AS avg_compound_ratio
FROM uspd_analytics_den.analytics_gold.contract_price_live_forecasted_v23
WHERE forecasted_contract_price > 2 * forecast_start_contract_price
GROUP BY cust_prod_category, trend_source
ORDER BY explosion_rows DESC;
-- Expect: 0 rows

-- Q4: Forecast profile at key horizons — 12, 24, 36, 60 months
SELECT
    cust_prod_category,
    forecast_horizon_month_num,
    COUNT(DISTINCT groupby_key)                         AS key_count,
    ROUND(SUM(forecasted_contract_price * anchor_total_sls_qty) / 1e6, 1)
                                                        AS forecasted_dollars_mm,
    ROUND(AVG(forecasted_contract_price
              / NULLIF(forecast_start_contract_price, 0)), 3) AS avg_compound_ratio
FROM uspd_analytics_den.analytics_gold.contract_price_live_forecasted_v23
WHERE forecast_horizon_month_num IN (12, 24, 36, 60)
GROUP BY cust_prod_category, forecast_horizon_month_num
ORDER BY cust_prod_category, forecast_horizon_month_num;

-- Q5: Spot-check known drugs — XARELTO should show ~5% annual step-up
SELECT
    groupby_key,
    jump_off_month,
    trend_source,
    resolved_monthly_trend_pct,
    forecast_start_contract_price,
    anchor_contract_price,
    typical_increase_month
FROM uspd_analytics_den.analytics_gold.contract_price_live_resolved_assumptions_v23
WHERE groupby_key IN (
    '952635|1413756|Retail|SNA|BX|23152|816',
    '952635|3748316|Retail|SNA|BX|23152|816'
);

-- Q6: Price source cap fire rate
SELECT
    cust_prod_category,
    forecast_start_price_source,
    SUM(forecast_start_price_capped_flag)               AS capped_count,
    COUNT(*)                                            AS total_count,
    ROUND(SUM(forecast_start_price_capped_flag)
          / NULLIF(COUNT(*), 0) * 100, 2)              AS cap_pct
FROM uspd_analytics_den.analytics_gold.contract_price_live_resolved_assumptions_v23
GROUP BY cust_prod_category, forecast_start_price_source
HAVING SUM(forecast_start_price_capped_flag) > 0
ORDER BY capped_count DESC;