/* ============================================================
   CONSOLIDATED MODELING QA REPORT
   TARGET: uspd_analytics_den.analytics_gold.contract_price_modeling_table_top_products

   PURPOSE:
   - duplicate check at modeling grain
   - overall MoM volatility
   - fallback-level risk
   - sparse / low-volume group risk
   - high-volatility group prevalence
   - mix-shift proxy
   ============================================================ */

WITH base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_table_top_products
),

params AS (
    SELECT
        0        AS max_duplicate_rows,
        0.30     AS max_avg_mom_price_change,           -- baseline-friendly target
        0.20     AS max_pct_rows_fallback_non_pf,       -- ideal if most rows come from PF
        0.10     AS max_pct_rows_unknown_group,         -- unknown should stay low
        0.20     AS max_pct_groups_sparse,              -- sparse groups threshold
        0.20     AS max_pct_groups_low_volume,          -- low-volume groups threshold
        0.30     AS max_pct_groups_high_volatility,     -- share of groups above high-vol threshold
        0.10     AS low_avg_monthly_qty_threshold,      -- low support threshold
        6        AS sparse_month_threshold,             -- sparse if < 6 months observed
        1.00     AS high_volatility_threshold           -- avg MoM > 100%
),

/* ============================================================
   1) Duplicate check at modeling grain
   ============================================================ */
duplicate_check AS (
    SELECT COUNT(*) AS duplicate_rows
    FROM (
        SELECT
            YEAR_MONTH,
            MODEL_GROUPBYKEYID,
            COUNT(*) AS cnt
        FROM base
        GROUP BY YEAR_MONTH, MODEL_GROUPBYKEYID
        HAVING COUNT(*) > 1
    ) d
),

/* ============================================================
   2) Row distribution by fallback level
   ============================================================ */
fallback_rows AS (
    SELECT
        COUNT(*) AS total_rows,
        SUM(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'PRODUCT_FAMILY' THEN 1 ELSE 0 END) AS rows_pf,
        SUM(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'THERAPEUTIC_CLASS' THEN 1 ELSE 0 END) AS rows_tc,
        SUM(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'MANUFACTURER_NAME' THEN 1 ELSE 0 END) AS rows_mfr,
        SUM(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'UNKNOWN' THEN 1 ELSE 0 END) AS rows_unknown
    FROM base
),

/* ============================================================
   3) MoM volatility at row/grain level
   ============================================================ */
lagged AS (
    SELECT
        MODEL_GROUPBYKEYID,
        MODEL_GROUPBYKEY,
        FINAL_PRODUCT_GROUP,
        FINAL_PRODUCT_GROUP_LEVEL,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        YEAR_MONTH,
        CONTRACT_PRICE,
        TOTAL_SLS_QTY,
        TOTAL_NET_COS,
        contributing_rows,
        distinct_materials,
        LAG(CONTRACT_PRICE) OVER (
            PARTITION BY MODEL_GROUPBYKEYID
            ORDER BY YEAR_MONTH
        ) AS prev_price
    FROM base
),

scored AS (
    SELECT
        *,
        CASE
            WHEN prev_price IS NOT NULL AND prev_price <> 0
            THEN ABS(CONTRACT_PRICE - prev_price) / prev_price
            ELSE NULL
        END AS mom_price_change
    FROM lagged
),

mom_summary AS (
    SELECT
        AVG(mom_price_change) AS avg_mom_price_change,
        PERCENTILE_APPROX(mom_price_change, 0.50) AS median_mom_price_change,
        PERCENTILE_APPROX(mom_price_change, 0.90) AS p90_mom_price_change,
        MAX(mom_price_change) AS max_mom_price_change
    FROM scored
    WHERE mom_price_change IS NOT NULL
),

/* ============================================================
   4) Group-level support / volatility summary
   ============================================================ */
group_summary AS (
    SELECT
        MODEL_GROUPBYKEYID,
        MAX(MODEL_GROUPBYKEY) AS MODEL_GROUPBYKEY,
        MAX(FINAL_PRODUCT_GROUP) AS FINAL_PRODUCT_GROUP,
        MAX(FINAL_PRODUCT_GROUP_LEVEL) AS FINAL_PRODUCT_GROUP_LEVEL,
        MAX(CUST_SEGMENT) AS CUST_SEGMENT,
        MAX(ACCT_CLASSIFICATION) AS ACCT_CLASSIFICATION,
        MAX(CUST_PROD_CATEGORY) AS CUST_PROD_CATEGORY,

        COUNT(*) AS observed_months,
        AVG(TOTAL_SLS_QTY) AS avg_monthly_qty,
        MIN(TOTAL_SLS_QTY) AS min_monthly_qty,
        AVG(contributing_rows) AS avg_contributing_rows,
        AVG(distinct_materials) AS avg_distinct_materials,
        AVG(CONTRACT_PRICE) AS avg_contract_price,
        STDDEV(CONTRACT_PRICE) AS std_contract_price,
        AVG(mom_price_change) AS avg_mom_price_change,
        MAX(mom_price_change) AS max_mom_price_change
    FROM scored
    WHERE mom_price_change IS NOT NULL
    GROUP BY MODEL_GROUPBYKEYID
),

group_rollup AS (
    SELECT
        COUNT(*) AS total_groups,

        SUM(CASE WHEN observed_months < (SELECT sparse_month_threshold FROM params) THEN 1 ELSE 0 END) AS sparse_groups,

        SUM(CASE WHEN avg_monthly_qty < (SELECT low_avg_monthly_qty_threshold FROM params) THEN 1 ELSE 0 END) AS low_volume_groups,

        SUM(CASE WHEN avg_mom_price_change > (SELECT high_volatility_threshold FROM params) THEN 1 ELSE 0 END) AS high_volatility_groups,

        AVG(observed_months) AS avg_observed_months,
        AVG(avg_monthly_qty) AS avg_group_monthly_qty,
        AVG(avg_contributing_rows) AS avg_group_contributing_rows,
        AVG(avg_distinct_materials) AS avg_group_distinct_materials
    FROM group_summary
),

/* ============================================================
   5) Volatility by fallback level
   ============================================================ */
fallback_volatility AS (
    SELECT
        FINAL_PRODUCT_GROUP_LEVEL,
        AVG(mom_price_change) AS avg_mom_price_change
    FROM scored
    WHERE mom_price_change IS NOT NULL
    GROUP BY FINAL_PRODUCT_GROUP_LEVEL
),

fallback_volatility_rollup AS (
    SELECT
        MAX(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'PRODUCT_FAMILY' THEN avg_mom_price_change END) AS pf_avg_mom,
        MAX(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'THERAPEUTIC_CLASS' THEN avg_mom_price_change END) AS tc_avg_mom,
        MAX(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'MANUFACTURER_NAME' THEN avg_mom_price_change END) AS mfr_avg_mom,
        MAX(CASE WHEN FINAL_PRODUCT_GROUP_LEVEL = 'UNKNOWN' THEN avg_mom_price_change END) AS unknown_avg_mom
    FROM fallback_volatility
),

/* ============================================================
   6) Mix-shift proxy:
   avg month-over-month change in distinct_materials
   ============================================================ */
mix_shift AS (
    SELECT
        MODEL_GROUPBYKEYID,
        YEAR_MONTH,
        distinct_materials,
        LAG(distinct_materials) OVER (
            PARTITION BY MODEL_GROUPBYKEYID
            ORDER BY YEAR_MONTH
        ) AS prev_distinct_materials
    FROM base
),

mix_shift_summary AS (
    SELECT
        AVG(
            CASE
                WHEN prev_distinct_materials IS NOT NULL
                THEN ABS(distinct_materials - prev_distinct_materials)
                ELSE NULL
            END
        ) AS avg_mom_distinct_material_change
    FROM mix_shift
),

/* ============================================================
   Final single report
   ============================================================ */
qa_report AS (

    /* duplicates */
    SELECT
        'duplicate_rows_at_modeling_grain' AS check_name,
        CASE
            WHEN duplicate_rows <= (SELECT max_duplicate_rows FROM params) THEN 'PASS'
            ELSE 'FAIL'
        END AS status,
        CAST(duplicate_rows AS DOUBLE) AS metric_value,
        CAST((SELECT max_duplicate_rows FROM params) AS DOUBLE) AS threshold,
        'Rows duplicated at YEAR_MONTH + MODEL_GROUPBYKEYID grain' AS detail
    FROM duplicate_check

    UNION ALL

    /* overall avg mom */
    SELECT
        'avg_mom_price_change' AS check_name,
        CASE
            WHEN avg_mom_price_change <= (SELECT max_avg_mom_price_change FROM params) THEN 'PASS'
            WHEN avg_mom_price_change <= 1.0 THEN 'WARN'
            ELSE 'FAIL'
        END AS status,
        CAST(avg_mom_price_change AS DOUBLE) AS metric_value,
        CAST((SELECT max_avg_mom_price_change FROM params) AS DOUBLE) AS threshold,
        CONCAT(
            'median=',
            CAST(median_mom_price_change AS STRING),
            ', p90=',
            CAST(p90_mom_price_change AS STRING),
            ', max=',
            CAST(max_mom_price_change AS STRING)
        ) AS detail
    FROM mom_summary

    UNION ALL

    /* pct rows not using product family fallback */
    SELECT
        'pct_rows_not_product_family' AS check_name,
        CASE
            WHEN (rows_tc + rows_mfr + rows_unknown) * 1.0 / total_rows <= (SELECT max_pct_rows_fallback_non_pf FROM params) THEN 'PASS'
            WHEN (rows_tc + rows_mfr + rows_unknown) * 1.0 / total_rows <= 0.40 THEN 'WARN'
            ELSE 'FAIL'
        END AS status,
        CAST((rows_tc + rows_mfr + rows_unknown) * 1.0 / total_rows AS DOUBLE) AS metric_value,
        CAST((SELECT max_pct_rows_fallback_non_pf FROM params) AS DOUBLE) AS threshold,
        CONCAT(
            'PF=', CAST(rows_pf AS STRING),
            ', TC=', CAST(rows_tc AS STRING),
            ', MFR=', CAST(rows_mfr AS STRING),
            ', UNKNOWN=', CAST(rows_unknown AS STRING),
            ', total=', CAST(total_rows AS STRING)
        ) AS detail
    FROM fallback_rows

    UNION ALL

    /* pct rows unknown */
    SELECT
        'pct_rows_unknown_product_group' AS check_name,
        CASE
            WHEN rows_unknown * 1.0 / total_rows <= (SELECT max_pct_rows_unknown_group FROM params) THEN 'PASS'
            WHEN rows_unknown * 1.0 / total_rows <= 0.20 THEN 'WARN'
            ELSE 'FAIL'
        END AS status,
        CAST(rows_unknown * 1.0 / total_rows AS DOUBLE) AS metric_value,
        CAST((SELECT max_pct_rows_unknown_group FROM params) AS DOUBLE) AS threshold,
        CONCAT(
            CAST(rows_unknown AS STRING),
            ' UNKNOWN rows out of ',
            CAST(total_rows AS STRING)
        ) AS detail
    FROM fallback_rows

    UNION ALL

    /* sparse groups */
    SELECT
        'pct_sparse_groups_lt_6_months' AS check_name,
        CASE
            WHEN sparse_groups * 1.0 / total_groups <= (SELECT max_pct_groups_sparse FROM params) THEN 'PASS'
            WHEN sparse_groups * 1.0 / total_groups <= 0.35 THEN 'WARN'
            ELSE 'FAIL'
        END AS status,
        CAST(sparse_groups * 1.0 / total_groups AS DOUBLE) AS metric_value,
        CAST((SELECT max_pct_groups_sparse FROM params) AS DOUBLE) AS threshold,
        CONCAT(
            CAST(sparse_groups AS STRING),
            ' sparse groups out of ',
            CAST(total_groups AS STRING),
            '; avg_observed_months=',
            CAST(avg_observed_months AS STRING)
        ) AS detail
    FROM group_rollup

    UNION ALL

    /* low volume groups */
    SELECT
        'pct_low_volume_groups_avg_qty_lt_10' AS check_name,
        CASE
            WHEN low_volume_groups * 1.0 / total_groups <= (SELECT max_pct_groups_low_volume FROM params) THEN 'PASS'
            WHEN low_volume_groups * 1.0 / total_groups <= 0.35 THEN 'WARN'
            ELSE 'FAIL'
        END AS status,
        CAST(low_volume_groups * 1.0 / total_groups AS DOUBLE) AS metric_value,
        CAST((SELECT max_pct_groups_low_volume FROM params) AS DOUBLE) AS threshold,
        CONCAT(
            CAST(low_volume_groups AS STRING),
            ' low-volume groups out of ',
            CAST(total_groups AS STRING),
            '; avg_group_monthly_qty=',
            CAST(avg_group_monthly_qty AS STRING)
        ) AS detail
    FROM group_rollup

    UNION ALL

    /* high volatility groups */
    SELECT
        'pct_groups_avg_mom_gt_100pct' AS check_name,
        CASE
            WHEN high_volatility_groups * 1.0 / total_groups <= (SELECT max_pct_groups_high_volatility FROM params) THEN 'PASS'
            WHEN high_volatility_groups * 1.0 / total_groups <= 0.50 THEN 'WARN'
            ELSE 'FAIL'
        END AS status,
        CAST(high_volatility_groups * 1.0 / total_groups AS DOUBLE) AS metric_value,
        CAST((SELECT max_pct_groups_high_volatility FROM params) AS DOUBLE) AS threshold,
        CONCAT(
            CAST(high_volatility_groups AS STRING),
            ' highly volatile groups out of ',
            CAST(total_groups AS STRING)
        ) AS detail
    FROM group_rollup

    UNION ALL

    /* fallback-level comparative volatility */
    SELECT
        'avg_mom_pf_vs_tc_vs_mfr_vs_unknown' AS check_name,
        'INFO' AS status,
        CAST(pf_avg_mom AS DOUBLE) AS metric_value,
        NULL AS threshold,
        CONCAT(
            'PF=', CAST(pf_avg_mom AS STRING),
            ', TC=', CAST(tc_avg_mom AS STRING),
            ', MFR=', CAST(mfr_avg_mom AS STRING),
            ', UNKNOWN=', CAST(unknown_avg_mom AS STRING)
        ) AS detail
    FROM fallback_volatility_rollup

    UNION ALL

    /* mix-shift proxy */
    SELECT
        'avg_mom_distinct_material_change' AS check_name,
        'INFO' AS status,
        CAST(avg_mom_distinct_material_change AS DOUBLE) AS metric_value,
        NULL AS threshold,
        'Average month-over-month change in distinct_materials within modeling groups' AS detail
    FROM mix_shift_summary
)

SELECT *
FROM qa_report
ORDER BY
    CASE
        WHEN status = 'FAIL' THEN 0
        WHEN status = 'WARN' THEN 1
        WHEN status = 'PASS' THEN 2
        ELSE 3
    END,
    check_name;

SELECT
    FINAL_PRODUCT_GROUP_LEVEL,
    COUNT(*) * 1.0 / SUM(COUNT(*)) OVER() AS pct_of_rows
FROM uspd_analytics_den.analytics_gold.contract_price_modeling_table_top_products
GROUP BY FINAL_PRODUCT_GROUP_LEVEL;
