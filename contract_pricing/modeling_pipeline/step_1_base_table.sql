CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_modeling_base_v10 AS

-- ============================================================
-- COVERAGE CTEs
-- Computed on the raw source before any aggregation so that
-- month counts reflect row-level grain, not aggregated grain.
-- Both CTEs build the same key strings used later in agg/final.
-- ============================================================
WITH src AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.vw_q_contract_price_base_v9
    WHERE YEAR_MONTH IS NOT NULL
      AND MTRL_NUM IS NOT NULL
      AND TRIM(MTRL_NUM) <> ''
      AND TOTAL_SLS_QTY IS NOT NULL
      AND TOTAL_SLS_QTY >= 0
      AND TOTAL_ZOMBIE_SALES < 1
      AND WAC_SPREAD_FLAG = 'VALID'
    --   AND UNIT_BILL_UOM = 'EA'
),

-- SAP-level key coverage: required dims + sap_cust_num_trim
sap_coverage AS (
    SELECT
        CONCAT_WS('|',
            MTRL_NUM,
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            COALESCE(sap_cust_num_trim, 'NA')
        ) AS sap_key,

        COUNT(DISTINCT YEAR_MONTH) AS sap_months
    FROM src
    GROUP BY
        CONCAT_WS('|',
            MTRL_NUM,
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            COALESCE(sap_cust_num_trim, 'NA')
        )
),

-- L2-level key coverage: required dims + segment-aware group ID
l2_coverage AS (
    SELECT
        CONCAT_WS('|',
            MTRL_NUM,
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            COALESCE(
                CASE
                    WHEN cust_segment_cd IN ('F','H') THEN CAST(COMMON_GRP_ID AS STRING)
                    WHEN cust_segment_cd IN ('C','D','W') THEN CAST(CHAIN_ID AS STRING)
                    ELSE CAST(COMMON_GRP_ID AS STRING)
                END,
            'NA')
        ) AS l2_key,

        COUNT(DISTINCT YEAR_MONTH) AS l2_months
    FROM src
    GROUP BY
        CONCAT_WS('|',
            MTRL_NUM,
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY,
            COALESCE(
                CASE
                    WHEN cust_segment_cd IN ('F','H') THEN CAST(COMMON_GRP_ID AS STRING)
                    WHEN cust_segment_cd IN ('C','D','W') THEN CAST(CHAIN_ID AS STRING)
                    ELSE CAST(COMMON_GRP_ID AS STRING)
                END,
            'NA')
        )
),

normalized AS (
    SELECT
        TO_DATE(s.YEAR_MONTH || '-01') AS cal_month_start_dt,
        s.YEAR_MONTH,

        s.CUST_SEGMENT,
        s.cust_segment_cd,
        s.CUST_NAME,
        s.ACCT_CLASSIFICATION,
        s.account_class_cd,
        s.CUST_PROD_CATEGORY,

        s.NATIONAL_GRP_ID,
        s.NATIONAL_GRP_DESC,

        s.COMMON_GRP_ID,
        s.COMMON_GRP_DESC,

        s.CHAIN_ID,
        s.CHAIN_DESC,

        s.SUBSET_L2_ID,
        s.SUBSET_L2_DESC,

        s.MTRL_NUM,
        s.MTRL_NME_NVGTON,

        s.NDC_NUM AS ndc_num,

        s.PRODUCT_FAMILY,
        s.THERAPEUTIC_CLASS,
        s.MANUFACTURER_ID,
        s.MANUFACTURER_NAME,

        s.TOTAL_NET_COS,
        s.TOTAL_SLS_QTY,
        s.WAC_WEIGHTED,
        s.UNIT_BILL_UOM,

        -- resolved product group
        CASE
            WHEN s.PRODUCT_FAMILY IS NOT NULL
             AND TRIM(s.PRODUCT_FAMILY) <> ''
             AND s.PRODUCT_FAMILY <> 'UNKNOWN'
                THEN s.PRODUCT_FAMILY
            WHEN s.THERAPEUTIC_CLASS IS NOT NULL
             AND TRIM(s.THERAPEUTIC_CLASS) <> ''
             AND s.THERAPEUTIC_CLASS <> 'UNKNOWN'
                THEN s.THERAPEUTIC_CLASS
            WHEN s.MANUFACTURER_NAME IS NOT NULL
             AND TRIM(s.MANUFACTURER_NAME) <> ''
             AND s.MANUFACTURER_NAME <> 'UNKNOWN'
                THEN s.MANUFACTURER_NAME
            ELSE 'UNKNOWN'
        END AS final_product_group,

        CASE
            WHEN s.PRODUCT_FAMILY IS NOT NULL
             AND TRIM(s.PRODUCT_FAMILY) <> ''
             AND s.PRODUCT_FAMILY <> 'UNKNOWN'
                THEN 'PRODUCT_FAMILY'
            WHEN s.THERAPEUTIC_CLASS IS NOT NULL
             AND TRIM(s.THERAPEUTIC_CLASS) <> ''
             AND s.THERAPEUTIC_CLASS <> 'UNKNOWN'
                THEN 'THERAPEUTIC_CLASS'
            WHEN s.MANUFACTURER_NAME IS NOT NULL
             AND TRIM(s.MANUFACTURER_NAME) <> ''
             AND s.MANUFACTURER_NAME <> 'UNKNOWN'
                THEN 'MANUFACTURER_NAME'
            ELSE 'UNKNOWN'
        END AS final_product_group_level,

        -- original customer group key retained for backward compatibility
        CONCAT_WS('|',
            s.MANUFACTURER_ID,
            s.NATIONAL_GRP_ID,
            s.CUST_SEGMENT,
            s.ACCT_CLASSIFICATION,
            s.CUST_PROD_CATEGORY
        ) AS customer_group_key_id,

        CONCAT_WS('|',
            s.MANUFACTURER_NAME,
            s.NATIONAL_GRP_DESC,
            s.CUST_SEGMENT,
            s.ACCT_CLASSIFICATION,
            s.CUST_PROD_CATEGORY
        ) AS customer_group_key_desc,

        -- --------------------------------------------------------
        -- THREE-TIER HYBRID KEY COMPONENTS
        -- --------------------------------------------------------
        s.sap_cust_num_trim,

        -- L2 ID: segment-aware intermediate group
        COALESCE(
            CASE
                WHEN s.cust_segment_cd IN ('F','H') THEN CAST(s.COMMON_GRP_ID AS STRING)
                WHEN s.cust_segment_cd IN ('C','D','W') THEN CAST(s.CHAIN_ID AS STRING)
                ELSE CAST(s.COMMON_GRP_ID AS STRING)
            END,
        'NA') AS subset_l2_id_resolved,

        -- L2 DESC: mirrors same segment-aware logic as L2 ID
        COALESCE(
            CASE
                WHEN s.cust_segment_cd IN ('F','H') THEN CAST(s.COMMON_GRP_DESC AS STRING)
                WHEN s.cust_segment_cd IN ('C','D','W') THEN CAST(s.CHAIN_DESC AS STRING)
                ELSE CAST(s.COMMON_GRP_DESC AS STRING)
            END,
        'NA') AS subset_l2_desc_resolved,

        -- Useful QA/debug field: tells which description is being used
        CASE
            WHEN s.cust_segment_cd IN ('F','H') THEN 'COMMON_GRP_DESC'
            WHEN s.cust_segment_cd IN ('C','D','W') THEN 'CHAIN_DESC'
            ELSE 'COMMON_GRP_DESC'
        END AS subset_l2_desc_source,

        -- SAP key: ID version
        CONCAT_WS('|',
            s.MTRL_NUM,
            s.CUST_SEGMENT,
            s.ACCT_CLASSIFICATION,
            s.CUST_PROD_CATEGORY,
            COALESCE(s.sap_cust_num_trim, 'NA')
        ) AS sap_key,

        -- SAP key: readable desc version
        CONCAT_WS('|',
            CONCAT('MTRL_NME_NVGTON=', COALESCE(CAST(s.MTRL_NME_NVGTON AS STRING), 'NA')),
            CONCAT('CUST_SEGMENT=', COALESCE(CAST(s.CUST_SEGMENT AS STRING), 'NA')),
            CONCAT('ACCT_CLASSIFICATION=', COALESCE(CAST(s.ACCT_CLASSIFICATION AS STRING), 'NA')),
            CONCAT('CUST_PROD_CATEGORY=', COALESCE(CAST(s.CUST_PROD_CATEGORY AS STRING), 'NA')),
            CONCAT('CUST_NAME=', COALESCE(CAST(s.CUST_NAME AS STRING), 'NA'))
        ) AS sap_key_desc,

        -- L2 key: ID version
        CONCAT_WS('|',
            s.MTRL_NUM,
            s.CUST_SEGMENT,
            s.ACCT_CLASSIFICATION,
            s.CUST_PROD_CATEGORY,
            COALESCE(
                CASE
                    WHEN s.cust_segment_cd IN ('F','H') THEN CAST(s.COMMON_GRP_ID AS STRING)
                    WHEN s.cust_segment_cd IN ('C','D','W') THEN CAST(s.CHAIN_ID AS STRING)
                    ELSE CAST(s.COMMON_GRP_ID AS STRING)
                END,
            'NA')
        ) AS l2_key,

        -- L2 key: readable desc version
        CONCAT_WS('|',
            CONCAT('MTRL_NME_NVGTON=', COALESCE(CAST(s.MTRL_NME_NVGTON AS STRING), 'NA')),
            CONCAT('CUST_SEGMENT=', COALESCE(CAST(s.CUST_SEGMENT AS STRING), 'NA')),
            CONCAT('ACCT_CLASSIFICATION=', COALESCE(CAST(s.ACCT_CLASSIFICATION AS STRING), 'NA')),
            CONCAT('CUST_PROD_CATEGORY=', COALESCE(CAST(s.CUST_PROD_CATEGORY AS STRING), 'NA')),
            CONCAT(
                CASE
                    WHEN s.cust_segment_cd IN ('F','H') THEN 'COMMON_GRP_DESC='
                    WHEN s.cust_segment_cd IN ('C','D','W') THEN 'CHAIN_DESC='
                    ELSE 'COMMON_GRP_DESC='
                END,
                COALESCE(
                    CAST(
                        CASE
                            WHEN s.cust_segment_cd IN ('F','H') THEN s.COMMON_GRP_DESC
                            WHEN s.cust_segment_cd IN ('C','D','W') THEN s.CHAIN_DESC
                            ELSE s.COMMON_GRP_DESC
                        END AS STRING
                    ),
                    'NA'
                )
            )
        ) AS l2_key_desc,

        -- National group fallback key: ID version
        CONCAT_WS('|',
            s.MTRL_NUM,
            s.CUST_SEGMENT,
            s.ACCT_CLASSIFICATION,
            s.CUST_PROD_CATEGORY,
            COALESCE(s.NATIONAL_GRP_ID, 'NA')
        ) AS nat_key,

        -- National group fallback key: readable desc version
        CONCAT_WS('|',
            CONCAT('MTRL_NME_NVGTON=', COALESCE(CAST(s.MTRL_NME_NVGTON AS STRING), 'NA')),
            CONCAT('CUST_SEGMENT=', COALESCE(CAST(s.CUST_SEGMENT AS STRING), 'NA')),
            CONCAT('ACCT_CLASSIFICATION=', COALESCE(CAST(s.ACCT_CLASSIFICATION AS STRING), 'NA')),
            CONCAT('CUST_PROD_CATEGORY=', COALESCE(CAST(s.CUST_PROD_CATEGORY AS STRING), 'NA')),
            CONCAT('NATIONAL_GRP_DESC=', COALESCE(CAST(s.NATIONAL_GRP_DESC AS STRING), 'NA'))
        ) AS nat_key_desc

    FROM src s
),

agg AS (
    SELECT
        n.cal_month_start_dt,
        n.YEAR_MONTH,

        n.CUST_SEGMENT,
        n.ACCT_CLASSIFICATION,
        n.account_class_cd,
        n.CUST_PROD_CATEGORY,

        n.NATIONAL_GRP_ID,
        n.NATIONAL_GRP_DESC,

        n.customer_group_key_id,
        n.customer_group_key_desc,
        n.UNIT_BILL_UOM,

        n.MTRL_NUM,
        MAX(n.MTRL_NME_NVGTON)                  AS MTRL_NME_NVGTON,
        MAX(n.ndc_num)                          AS ndc_num,

        MAX(n.PRODUCT_FAMILY)                   AS PRODUCT_FAMILY,
        MAX(n.THERAPEUTIC_CLASS)                AS THERAPEUTIC_CLASS,
        MAX(n.MANUFACTURER_ID)                  AS MANUFACTURER_ID,
        MAX(n.MANUFACTURER_NAME)                AS MANUFACTURER_NAME,
        MAX(n.final_product_group)              AS final_product_group,
        MAX(n.final_product_group_level)        AS final_product_group_level,

        -- Customer hierarchy description fields
        MAX(n.CUST_NAME)                        AS CUST_NAME,
        MAX(n.COMMON_GRP_ID)                    AS COMMON_GRP_ID,
        MAX(n.COMMON_GRP_DESC)                  AS COMMON_GRP_DESC,
        MAX(n.CHAIN_ID)                         AS CHAIN_ID,
        MAX(n.CHAIN_DESC)                       AS CHAIN_DESC,
        MAX(n.SUBSET_L2_ID)                     AS SUBSET_L2_ID,
        MAX(n.SUBSET_L2_DESC)                   AS SUBSET_L2_DESC,

        -- Three-tier hybrid components
        n.sap_cust_num_trim,
        MAX(n.subset_l2_id_resolved)            AS subset_l2_id_resolved,
        MAX(n.subset_l2_desc_resolved)          AS subset_l2_desc_resolved,
        MAX(n.subset_l2_desc_source)            AS subset_l2_desc_source,

        MAX(n.sap_key)                          AS sap_key,
        MAX(n.l2_key)                           AS l2_key,
        MAX(n.nat_key)                          AS nat_key,

        MAX(n.sap_key_desc)                     AS sap_key_desc,
        MAX(n.l2_key_desc)                      AS l2_key_desc,
        MAX(n.nat_key_desc)                     AS nat_key_desc,

        COUNT(*)                                AS contributing_rows,

        SUM(n.TOTAL_NET_COS)                    AS TOTAL_NET_COS,
        SUM(n.TOTAL_SLS_QTY)                    AS TOTAL_SLS_QTY,

        SUM(n.TOTAL_NET_COS)
            / NULLIF(SUM(n.TOTAL_SLS_QTY), 0)   AS contract_price,

        -- WAC_WEIGHTED from source view is already per-unit.
        -- Re-weight across normalized rows using quantity as the weight.
        SUM(n.WAC_WEIGHTED * n.TOTAL_SLS_QTY)
            / NULLIF(
                SUM(
                    CASE
                        WHEN n.WAC_WEIGHTED IS NOT NULL
                            THEN n.TOTAL_SLS_QTY
                    END
                ),
            0)                                  AS wac_weighted,

        (
            SUM(n.TOTAL_NET_COS)
            / NULLIF(
                SUM(
                    CASE
                        WHEN n.WAC_WEIGHTED IS NOT NULL
                            THEN n.WAC_WEIGHTED * n.TOTAL_SLS_QTY
                    END
                ),
            0)
        ) - 1                                   AS wac_spread

    FROM normalized n
    GROUP BY
        n.cal_month_start_dt,
        n.YEAR_MONTH,
        n.CUST_SEGMENT,
        n.ACCT_CLASSIFICATION,
        n.account_class_cd,
        n.CUST_PROD_CATEGORY,
        n.NATIONAL_GRP_ID,
        n.NATIONAL_GRP_DESC,
        n.UNIT_BILL_UOM,
        n.customer_group_key_id,
        n.customer_group_key_desc,
        n.MTRL_NUM,
        n.sap_cust_num_trim
),

-- --------------------------------------------------------
-- JOIN coverage counts onto aggregated rows, then resolve tier
-- --------------------------------------------------------
tiered AS (
    SELECT
        a.*,
        sc.sap_months,
        lc.l2_months,

        CASE
            WHEN sc.sap_months >= 6 THEN 'SAP_CUST'
            WHEN lc.l2_months  >= 6 THEN 'L2'
            ELSE 'NATIONAL_GRP_FALLBACK'
        END AS MODEL_TIER,

        CASE
            WHEN sc.sap_months >= 6 THEN a.sap_key
            WHEN lc.l2_months  >= 6 THEN a.l2_key
            ELSE                         a.nat_key
        END AS HYBRID_MODEL_KEY_3T,

        CASE
            WHEN sc.sap_months >= 6 THEN a.sap_key_desc
            WHEN lc.l2_months  >= 6 THEN a.l2_key_desc
            ELSE                         a.nat_key_desc
        END AS HYBRID_MODEL_KEY_3T_DESC

    FROM agg a
    LEFT JOIN sap_coverage sc
        ON sc.sap_key = a.sap_key
    LEFT JOIN l2_coverage lc
        ON lc.l2_key = a.l2_key
),

flagged AS (
    SELECT
        t.*,

        CASE
            WHEN contract_price < 0 THEN 1
            ELSE 0
        END AS negative_contract_price_flag,

        CASE
            WHEN TOTAL_SLS_QTY < 3 THEN 1
            ELSE 0
        END AS low_qty_flag,

        CASE
            WHEN ABS(TOTAL_NET_COS) < 1 THEN 1
            ELSE 0
        END AS low_ncos_flag,

        CASE
            WHEN wac_weighted IS NULL
              OR wac_weighted <= 0 THEN 1
            ELSE 0
        END AS invalid_wac_flag,

        CASE
            WHEN acct_classification IN ('WAC', '340B-CP', '340B-CE') THEN 0
            WHEN wac_weighted IS NULL OR wac_weighted <= 0 THEN 0
            WHEN contract_price > wac_weighted * 1.05 THEN 1
            ELSE 0
        END AS contract_price_above_wac_flag,

        CASE
            WHEN contract_price IS NULL THEN 1
            WHEN TOTAL_SLS_QTY = 0 THEN 1
            WHEN ABS(TOTAL_NET_COS) < 1 THEN 1
            WHEN TOTAL_SLS_QTY < 3 THEN 1
            WHEN contract_price < 0 THEN 1
            WHEN acct_classification IN ('WAC', '340B-CP', '340B-CE') THEN 0
            WHEN wac_weighted IS NOT NULL
             AND wac_weighted > 0
             AND contract_price > wac_weighted * 1.05 THEN 1
            ELSE 0
        END AS exclude_from_training_flag

    FROM tiered t
),

series_stats AS (
    SELECT
        f.*,

        HYBRID_MODEL_KEY_3T AS groupby_key,

        MEDIAN(
            CASE
                WHEN exclude_from_training_flag = 0
                    THEN contract_price
            END
        ) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, MTRL_NUM
        ) AS median_contract_price,

        STDDEV_SAMP(
            CASE
                WHEN exclude_from_training_flag = 0
                    THEN contract_price
            END
        ) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, MTRL_NUM
        ) AS stddev_contract_price,

        COUNT(
            CASE
                WHEN exclude_from_training_flag = 0
                    THEN 1
            END
        ) OVER (
            PARTITION BY HYBRID_MODEL_KEY_3T, MTRL_NUM
        ) AS valid_time_series_points

    FROM flagged f
),

outlier_flagged AS (
    SELECT
        s.*,

        CASE
            WHEN exclude_from_training_flag = 1 THEN 0
            WHEN valid_time_series_points < 3 THEN 0
            WHEN stddev_contract_price IS NULL THEN 0
            WHEN stddev_contract_price = 0 THEN 0
            WHEN ABS(contract_price - median_contract_price)
                 > 4 * stddev_contract_price THEN 1
            ELSE 0
        END AS contract_price_outlier_flag,

        CASE
            WHEN exclude_from_training_flag = 0
             AND (
                    valid_time_series_points < 6
                 OR stddev_contract_price IS NULL
                 OR stddev_contract_price = 0
                 OR ABS(contract_price - median_contract_price)
                    <= 3 * stddev_contract_price
                 )
                THEN 1
            ELSE 0
        END AS include_in_avg_contract_price_flag

    FROM series_stats s
),

avg_contract_price_by_series AS (
    SELECT
        groupby_key,
        MTRL_NUM,

        AVG(
            CASE
                WHEN include_in_avg_contract_price_flag = 1
                    THEN contract_price
            END
        ) AS avg_contract_price_excl_outliers,

        SUM(
            CASE
                WHEN include_in_avg_contract_price_flag = 1
                    THEN TOTAL_NET_COS
            END
        ) / NULLIF(
            SUM(
                CASE
                    WHEN include_in_avg_contract_price_flag = 1
                        THEN TOTAL_SLS_QTY
                END
            ),
        0) AS qty_weighted_avg_contract_price_excl_outliers,

        COUNT(
            CASE
                WHEN include_in_avg_contract_price_flag = 1
                    THEN 1
            END
        ) AS months_used_in_avg_contract_price,

        COUNT(
            CASE
                WHEN contract_price_outlier_flag = 1
                    THEN 1
            END
        ) AS months_excluded_as_contract_price_outliers

    FROM outlier_flagged
    GROUP BY
        groupby_key,
        MTRL_NUM
)

SELECT
    o.*,

    a.avg_contract_price_excl_outliers,
    a.qty_weighted_avg_contract_price_excl_outliers,
    a.months_used_in_avg_contract_price,
    a.months_excluded_as_contract_price_outliers

FROM outlier_flagged o
LEFT JOIN avg_contract_price_by_series a
    ON a.groupby_key = o.groupby_key
   AND a.MTRL_NUM    = o.MTRL_NUM
;