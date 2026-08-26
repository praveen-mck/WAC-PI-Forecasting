-- Rebuild contract_price_last_actual_v24 with all needed columns
CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_last_actual_v24 AS
WITH ranked AS (
    SELECT
        b.groupby_key,
        b.cal_month_start_dt                            AS anchor_month,
        b.contract_price                                AS anchor_contract_price,
        b.wac_weighted                                  AS anchor_wac_weighted,
        b.wac_spread                                    AS anchor_wac_spread,
        b.total_sls_qty                                 AS anchor_total_sls_qty,
        b.total_net_cos                                 AS anchor_total_net_cos,
        ROW_NUMBER() OVER (
            PARTITION BY b.groupby_key
            ORDER BY b.cal_month_start_dt DESC
        )                                               AS rn
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v24 b
    WHERE b.exclude_from_actuals_flag = 0
      AND b.contract_price IS NOT NULL
      AND b.contract_price > 0
)
SELECT
    groupby_key,
    anchor_month,
    anchor_contract_price,
    anchor_wac_weighted,
    anchor_wac_spread,
    anchor_total_sls_qty,
    anchor_total_net_cos
FROM ranked
WHERE rn = 1;

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_latest_obs_v24 AS
WITH obs_ranked AS (
    SELECT
        b.groupby_key,
        b.cal_month_start_dt,
        b.total_net_cos,
        b.total_sls_qty,
        b.wac_spread,
        ROW_NUMBER() OVER (
            PARTITION BY b.groupby_key
            ORDER BY b.cal_month_start_dt DESC
        ) AS rn
    FROM uspd_analytics_den.analytics_gold.contract_price_modeling_base_v24 b
    WHERE b.exclude_from_actuals_flag = 0
      AND b.total_net_cos  IS NOT NULL
      AND b.total_sls_qty  IS NOT NULL
      AND b.total_sls_qty  > 0
),
latest_6 AS (
    SELECT
        groupby_key,
        COUNT(*)                                                AS latest_6_observed_months,
        NULLIF(SUM(total_net_cos), 0)
            / NULLIF(SUM(total_sls_qty), 0)                    AS latest_6_observed_avg_contract_price,
        AVG(wac_spread)                                        AS latest_6_observed_avg_wac_spread
    FROM obs_ranked
    WHERE rn <= 6
    GROUP BY groupby_key
)
SELECT
    groupby_key,
    latest_6_observed_months,
    latest_6_observed_avg_contract_price,
    latest_6_observed_avg_wac_spread
FROM latest_6;  

