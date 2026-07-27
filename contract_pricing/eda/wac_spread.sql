CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.WITH_DECREASE_FLAG AS

/* =========================================================
STEP 1: BASE ACTUALS (clean monthly WAC)
========================================================= */
--WAC PRICE HISTORY
WITH base_actuals AS (
    SELECT
        ndc_nmbr,
        mtrl_num,
        cal_month_start_dt,
        actual_wac
    FROM uspd_analytics_den.analytics_gold.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v9
),

/* =========================================================
STEP 2: PRICE CHANGE CALCULATION
========================================================= */

price_changes AS (
    SELECT
        b.*,

        LAG(actual_wac) OVER (
            PARTITION BY mtrl_num
            ORDER BY cal_month_start_dt
        ) AS prev_wac_price

    FROM base_actuals b
),

classified_changes AS (
    SELECT
        mtrl_num,
        ndc_nmbr,
        cal_month_start_dt,
        actual_wac,
        prev_wac_price,

        /* % change */
        CASE
            WHEN prev_wac_price IS NOT NULL AND prev_wac_price <> 0
            THEN (actual_wac - prev_wac_price) / prev_wac_price
        END AS price_change_pct,

        /* any decrease */
        CASE
            WHEN prev_wac_price IS NOT NULL
             AND actual_wac < prev_wac_price
            THEN 1 ELSE 0
        END AS decrease_event_flag,

        /* significant decrease ≥ 5% */
        CASE
            WHEN prev_wac_price IS NOT NULL
             AND prev_wac_price <> 0
             AND (actual_wac - prev_wac_price) / prev_wac_price <= -0.05
            THEN 1 ELSE 0
        END AS significant_decrease_event_flag

    FROM price_changes
),

/* =========================================================
STEP 3: MATERIAL-LEVEL DECREASE FLAGS
========================================================= */

decrease_flags AS (
    SELECT
        mtrl_num,

        MAX(decrease_event_flag) AS has_decrease_flag,

        MAX(significant_decrease_event_flag) AS has_significant_decrease_flag,

        COUNT(CASE WHEN decrease_event_flag = 1 THEN 1 END) AS decrease_event_count,

        COUNT(CASE WHEN significant_decrease_event_flag = 1 THEN 1 END) 
            AS significant_decrease_event_count,

        MIN(CASE WHEN decrease_event_flag = 1 THEN cal_month_start_dt END) 
            AS first_decrease_dt,

        MAX(CASE WHEN decrease_event_flag = 1 THEN cal_month_start_dt END) 
            AS last_decrease_dt,

        MIN(price_change_pct) AS min_decrease_pct

    FROM classified_changes
    GROUP BY mtrl_num
),

/* =========================================================
STEP 4: BASE FORECAST/EVAL TABLE (v9)
========================================================= */

eval_base AS (
    SELECT *
    FROM uspd_analytics_den.analytics_gold.WAC_PI_BT_EVAL_DETAIL_v9
),

/* =========================================================
STEP 5: FINAL JOIN
========================================================= */

final AS (
    SELECT
        e.*,
        COALESCE(d.has_decrease_flag, 0) AS has_decrease_flag,
        COALESCE(d.has_significant_decrease_flag, 0) AS has_significant_decrease_flag,
        d.decrease_event_count,
        d.significant_decrease_event_count,
        d.first_decrease_dt,
        d.last_decrease_dt,
        d.min_decrease_pct

    FROM eval_base e
    LEFT JOIN decrease_flags d
      ON e.mtrl_num = d.mtrl_num
)

SELECT *
FROM final;