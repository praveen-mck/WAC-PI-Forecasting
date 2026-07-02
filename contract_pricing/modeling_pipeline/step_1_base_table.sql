CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_modeling_base_v6 AS
WITH src AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.vw_q_contract_price_base_v6
    WHERE YEAR_MONTH IS NOT NULL
      AND MTRL_NUM IS NOT NULL
      AND TRIM(MTRL_NUM) <> ''
      AND TOTAL_SLS_QTY IS NOT NULL
      AND TOTAL_SLS_QTY >= 0
      AND TOTAL_ZOMBIE_SALES <1 
      AND WAC_SPREAD_FLAG = 'VALID'
),

normalized AS (
    SELECT
        TO_DATE(YEAR_MONTH || '-01') AS cal_month_start_dt,
        YEAR_MONTH,

        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        account_class_cd,
        CUST_PROD_CATEGORY,
        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        MTRL_NUM,
        MTRL_NME_NVGTON,

        /* optional if you add NDC upstream */
        NDC_NUM AS ndc_num,

        PRODUCT_FAMILY,
        THERAPEUTIC_CLASS,
        MANUFACTURER_ID,
        MANUFACTURER_NAME,

        TOTAL_NET_COS,
        TOTAL_SLS_QTY,
        WAC_WEIGHTED,

        /* resolved fallback attrs */
        CASE
            WHEN PRODUCT_FAMILY IS NOT NULL
             AND TRIM(PRODUCT_FAMILY) <> ''
             AND PRODUCT_FAMILY <> 'UNKNOWN'
                THEN PRODUCT_FAMILY
            WHEN THERAPEUTIC_CLASS IS NOT NULL
             AND TRIM(THERAPEUTIC_CLASS) <> ''
             AND THERAPEUTIC_CLASS <> 'UNKNOWN'
                THEN THERAPEUTIC_CLASS
            WHEN MANUFACTURER_NAME IS NOT NULL
             AND TRIM(MANUFACTURER_NAME) <> ''
             AND MANUFACTURER_NAME <> 'UNKNOWN'
                THEN MANUFACTURER_NAME
            ELSE 'UNKNOWN'
        END AS final_product_group,

        CASE
            WHEN PRODUCT_FAMILY IS NOT NULL
             AND TRIM(PRODUCT_FAMILY) <> ''
             AND PRODUCT_FAMILY <> 'UNKNOWN'
                THEN 'PRODUCT_FAMILY'
            WHEN THERAPEUTIC_CLASS IS NOT NULL
             AND TRIM(THERAPEUTIC_CLASS) <> ''
             AND THERAPEUTIC_CLASS <> 'UNKNOWN'
                THEN 'THERAPEUTIC_CLASS'
            WHEN MANUFACTURER_NAME IS NOT NULL
             AND TRIM(MANUFACTURER_NAME) <> ''
             AND MANUFACTURER_NAME <> 'UNKNOWN'
                THEN 'MANUFACTURER_NAME'
            ELSE 'UNKNOWN'
        END AS final_product_group_level,

        /* keep customer key explicit */
        CONCAT_WS('|',
            MANUFACTURER_ID,
            NATIONAL_GRP_ID,
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY
        ) AS customer_group_key_id,

        CONCAT_WS('|',
            MANUFACTURER_NAME,
            NATIONAL_GRP_DESC,
            CUST_SEGMENT,
            ACCT_CLASSIFICATION,
            CUST_PROD_CATEGORY
            
            
        ) AS customer_group_key_desc

    FROM src
),

agg AS (
    SELECT
        cal_month_start_dt,
        YEAR_MONTH,

        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        account_class_cd,
        CUST_PROD_CATEGORY,

        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,

        customer_group_key_id,
        customer_group_key_desc,

        MTRL_NUM,
        MAX(MTRL_NME_NVGTON) AS MTRL_NME_NVGTON,
        MAX(ndc_num) AS ndc_num,

        MAX(PRODUCT_FAMILY) AS PRODUCT_FAMILY,
        MAX(THERAPEUTIC_CLASS) AS THERAPEUTIC_CLASS,
        MAX(MANUFACTURER_ID) AS MANUFACTURER_ID,
        MAX(MANUFACTURER_NAME) AS MANUFACTURER_NAME,
        MAX(final_product_group) AS final_product_group,
        MAX(final_product_group_level) AS final_product_group_level,

        COUNT(*) AS contributing_rows,

        SUM(TOTAL_NET_COS) AS TOTAL_NET_COS,
        SUM(TOTAL_SLS_QTY) AS TOTAL_SLS_QTY,

        /* core target */
        SUM(TOTAL_NET_COS) / NULLIF(SUM(TOTAL_SLS_QTY), 0) AS contract_price,

        /* weighted WAC */
        SUM(WAC_WEIGHTED * TOTAL_SLS_QTY) / NULLIF(SUM(TOTAL_SLS_QTY), 0) AS wac_weighted,

        /* spread retained for diagnostics / alternate modeling */
        (
            SUM(TOTAL_NET_COS)
            / NULLIF(SUM(WAC_WEIGHTED * TOTAL_SLS_QTY), 0)
        ) - 1 AS wac_spread

    FROM normalized
    GROUP BY
        cal_month_start_dt,
        YEAR_MONTH,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        account_class_cd,
        CUST_PROD_CATEGORY,
        NATIONAL_GRP_ID,
        NATIONAL_GRP_DESC,
        customer_group_key_id,
        customer_group_key_desc,
        MTRL_NUM
),

flagged AS (
    SELECT
        a.*,

        CASE WHEN contract_price < 0 THEN 1 ELSE 0 END AS negative_contract_price_flag,
        CASE WHEN TOTAL_SLS_QTY < 3 THEN 1 ELSE 0 END AS low_qty_flag,
        CASE WHEN ABS(TOTAL_NET_COS) < 1 THEN 1 ELSE 0 END AS low_ncos_flag,
        CASE WHEN wac_weighted IS NULL OR wac_weighted <= 0 THEN 1 ELSE 0 END AS invalid_wac_flag,

        CASE
            WHEN contract_price IS NULL THEN 1
            WHEN TOTAL_SLS_QTY = 0 THEN 1
            WHEN ABS(TOTAL_NET_COS) < 1 THEN 1
            WHEN TOTAL_SLS_QTY < 3 THEN 1
            WHEN contract_price < 0 THEN 1
            ELSE 0
        END AS exclude_from_training_flag

    FROM agg a
),

series_stats AS (
    SELECT
        f.*,

        customer_group_key_id AS groupby_key,

        MEDIAN(
            CASE
                WHEN exclude_from_training_flag = 0
                THEN contract_price
            END
        ) OVER (
            PARTITION BY customer_group_key_id, MTRL_NUM
        ) AS median_contract_price,

        STDDEV_SAMP(
            CASE
                WHEN exclude_from_training_flag = 0
                THEN contract_price
            END
        ) OVER (
            PARTITION BY customer_group_key_id, MTRL_NUM
        ) AS stddev_contract_price,

        COUNT(
            CASE
                WHEN exclude_from_training_flag = 0
                THEN 1
            END
        ) OVER (
            PARTITION BY customer_group_key_id, MTRL_NUM
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
                 > 4 * stddev_contract_price
                THEN 1
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
        )
        /
        NULLIF(
            SUM(
                CASE
                    WHEN include_in_avg_contract_price_flag = 1
                    THEN TOTAL_SLS_QTY
                END
            ),
            0
        ) AS qty_weighted_avg_contract_price_excl_outliers,

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
       ON o.groupby_key = a.groupby_key
      AND o.MTRL_NUM = a.MTRL_NUM;