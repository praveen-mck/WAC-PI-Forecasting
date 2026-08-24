-- ══════════════════════════════════════════════════════════════════
-- Q1: contract_price_last_actual_v23
-- One row per groupby_key, anchor = most recent non-excluded month
-- ══════════════════════════════════════════════════════════════════

-- Q1a: Row count and uniqueness — should be one row per groupby_key
SELECT
    COUNT(*)                                            AS total_rows,
    COUNT(DISTINCT groupby_key)                         AS unique_keys,
    COUNT(*) - COUNT(DISTINCT groupby_key)              AS duplicate_keys
FROM uspd_analytics_den.analytics_gold.contract_price_last_actual_v23;
-- Expect: total_rows = unique_keys, duplicate_keys = 0

-- Q1b: Anchor month distribution — confirm it's recent
SELECT
    DATE_FORMAT(anchor_month, 'yyyy-MM')                AS anchor_ym,
    COUNT(*)                                            AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_last_actual_v23
GROUP BY anchor_ym
ORDER BY anchor_ym DESC
LIMIT 12;
-- Expect: most keys anchored within last 3-6 months

-- Q1c: No NULL or zero anchor prices
SELECT
    COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_last_actual_v23
WHERE anchor_contract_price IS NULL
   OR anchor_contract_price <= 0
   OR anchor_total_sls_qty IS NULL
   OR anchor_total_net_cos IS NULL;
-- Expect: 0

-- Q1d: Spot-check known key
SELECT *
FROM uspd_analytics_den.analytics_gold.contract_price_last_actual_v23
WHERE groupby_key = '755781|2324978|Retail|SNA|APOLLO|00152|945';
-- Expect: anchor_month = most recent month for SKYRIZI PEN


-- ══════════════════════════════════════════════════════════════════
-- Q2: contract_price_latest_obs_v23
-- One row per groupby_key, avg of latest 6 non-excluded months
-- ══════════════════════════════════════════════════════════════════

-- Q2a: Row count — should match last_actual (same key universe)
SELECT
    COUNT(*)                                            AS total_rows,
    COUNT(DISTINCT groupby_key)                         AS unique_keys
FROM uspd_analytics_den.analytics_gold.contract_price_latest_obs_v23;
-- Expect: matches Q1a unique_keys

-- Q2b: latest_6_observed_months distribution
SELECT
    latest_6_observed_months,
    COUNT(*)                                            AS key_count
FROM uspd_analytics_den.analytics_gold.contract_price_latest_obs_v23
GROUP BY latest_6_observed_months
ORDER BY latest_6_observed_months;
-- Expect: values 1-6 only, majority at 6

-- Q2c: No NULL prices
SELECT COUNT(*) AS bad_rows
FROM uspd_analytics_den.analytics_gold.contract_price_latest_obs_v23
WHERE latest_6_observed_avg_contract_price IS NULL
   OR latest_6_observed_avg_contract_price <= 0;
-- Expect: 0 (some NULLs possible for keys with only WAC-ceiling months)

-- Q2d: Cross-check latest_obs price vs last_actual anchor price
-- latest_6_observed should be close to anchor for stable-price keys
SELECT
    ROUND(AVG(ABS(lo.latest_6_observed_avg_contract_price
                  / NULLIF(la.anchor_contract_price, 0) - 1)) * 100, 2)
                                                        AS avg_pct_diff,
    ROUND(PERCENTILE(ABS(lo.latest_6_observed_avg_contract_price
                         / NULLIF(la.anchor_contract_price, 0) - 1), 0.5) * 100, 2)
                                                        AS median_pct_diff,
    ROUND(PERCENTILE(ABS(lo.latest_6_observed_avg_contract_price
                         / NULLIF(la.anchor_contract_price, 0) - 1), 0.95) * 100, 2)
                                                        AS p95_pct_diff
FROM uspd_analytics_den.analytics_gold.contract_price_latest_obs_v23 lo
JOIN uspd_analytics_den.analytics_gold.contract_price_last_actual_v23 la
  ON lo.groupby_key = la.groupby_key
WHERE lo.latest_6_observed_avg_contract_price IS NOT NULL;
-- Expect: median_pct_diff near 0%, avg < 10%, p95 < 50%
-- Large values indicate regime changes or data quality issues


-- ══════════════════════════════════════════════════════════════════
-- Q3: Cross-check live tables vs BT tables
-- Confirm live anchor matches BT anchor for the most recent BT run
-- ══════════════════════════════════════════════════════════════════
SELECT
    ROUND(AVG(ABS(live.anchor_contract_price
                  / NULLIF(bt.anchor_contract_price, 0) - 1)) * 100, 3)
                                                        AS avg_pct_diff,
    COUNT(DISTINCT live.groupby_key)                    AS matched_keys,
    SUM(CASE WHEN ABS(live.anchor_contract_price
                      / NULLIF(bt.anchor_contract_price, 0) - 1) > 0.01
             THEN 1 ELSE 0 END)                         AS keys_differ_over_1pct
FROM uspd_analytics_den.analytics_gold.contract_price_last_actual_v23 live
JOIN uspd_analytics_den.analytics_gold.contract_price_bt_last_actual_v23 bt
  ON live.groupby_key = bt.groupby_key
 AND bt.run_id = 'BT_2025_01';
-- Expect: avg_pct_diff near 0 for most keys.
-- keys_differ_over_1pct should be low — differences are legitimate
-- only if modeling_base was refreshed with newer data since BT_2025_01.