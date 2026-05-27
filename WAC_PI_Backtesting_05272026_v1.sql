

/* =====================================================================
   WAC PI BASELINE BACKTESTING - FULL UPDATED SCRIPT
   ---------------------------------------------------------------------
   DESIGN GOALS
   - Rolling-origin backtesting
   - 1:1 unique evaluation grain
   - Use:
       Actual Dollars     = Actual WAC * Actual QTY
       Forecasted Dollars = Forecasted WAC * Actual QTY
   - Remove low-WAC actuals only in CLEAN dashboard output
   - Add explosion flag for unrealistic forecast behavior
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: Backtest runs
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUNS AS
SELECT
    'BT_2024_01' AS run_id,
    TO_DATE('2024-01-01') AS jump_off_month,
    2 AS lookback_years,
    DATEADD(year, -2, TO_DATE('2024-01-01')) AS history_start_dt,
    DATEADD(day, -1, TO_DATE('2024-01-01')) AS history_end_dt,
    DATEADD(year, -1, TO_DATE('2024-01-01')) AS roll_1yr_start,
    DATEADD(year, -2, TO_DATE('2024-01-01')) AS roll_2yr_start

UNION ALL

SELECT
    'BT_2024_04' AS run_id,
    TO_DATE('2024-04-01') AS jump_off_month,
    2 AS lookback_years,
    DATEADD(year, -2, TO_DATE('2024-04-01')) AS history_start_dt,
    DATEADD(day, -1, TO_DATE('2024-04-01')) AS history_end_dt,
    DATEADD(year, -1, TO_DATE('2024-04-01')) AS roll_1yr_start,
    DATEADD(year, -2, TO_DATE('2024-04-01')) AS roll_2yr_start

UNION ALL

SELECT
    'BT_2025_01' AS run_id,
    TO_DATE('2025-01-01') AS jump_off_month,
    1 AS lookback_years,
    DATEADD(year, -1, TO_DATE('2025-01-01')) AS history_start_dt,
    DATEADD(day, -1, TO_DATE('2025-01-01')) AS history_end_dt,
    DATEADD(year, -1, TO_DATE('2025-01-01')) AS roll_1yr_start,
    DATEADD(year, -2, TO_DATE('2025-01-01')) AS roll_2yr_start
;


/* ---------------------------------------------------------------------
   STEP 1: Backtest universe
   - Deduplicate to one row per ndc + material
   - Keep the most frequent category if multiple exist
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE AS
WITH base AS (
    SELECT
        COPA_NDC_NUM       AS ndc_nmbr,
        COPA_MTRL_NUM      AS mtrl_num,
        CUST_PROD_CATEGORY AS cust_prod_category,
        COUNT(*) AS row_cnt
    FROM PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED
    WHERE COPA_NDC_NUM IS NOT NULL
      AND COPA_MTRL_NUM IS NOT NULL
    GROUP BY 1,2,3
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY ndc_nmbr, mtrl_num
            ORDER BY row_cnt DESC, cust_prod_category
        ) AS rn
    FROM base
)
SELECT
    ndc_nmbr,
    mtrl_num,
    cust_prod_category
FROM ranked
WHERE rn = 1
;


/* ---------------------------------------------------------------------
   STEP 2: Deduplicate attributes
   - One row per ndc + material
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP AS
WITH ranked AS (
    SELECT
        a.*,
        ROW_NUMBER() OVER (
            PARTITION BY a.ndc_nmbr, a.mtrl_num
            ORDER BY
                CASE WHEN a.therapeutic_class IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN a.manufacturer_name IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN a.sell_dscr IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN a.THERA_CLS_DSCR IS NOT NULL THEN 0 ELSE 1 END,
                a.ndc_nmbr,
                a.mtrl_num
        ) AS rn
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS a
)
SELECT
    ndc_nmbr,
    mtrl_num,
    cust_prod_category,
    therapeutic_class,
    sell_dscr,
    THRPTC_CLSS_CDE,
    THERA_CLS_DSCR,
    manufacturer_name,
    BYNG_DESC,
    ITM_CTVTY_CDE,
    MTRL_CURR_FLG,
    has_material_match,
    has_vstx_match,
    has_manufacturer_match,
    has_ahfs_match
FROM ranked
WHERE rn = 1
;


/* =====================================================================
   PATCH STEP 3: ACTUAL MONTHLY WAC
   - Rebuild uniquely at ndc + mtrl + month
   - Remove category from the grain to avoid row multiplication later
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY AS
WITH base AS (
    SELECT
        COPA_NDC_NUM         AS ndc_nmbr,
        COPA_MTRL_NUM        AS mtrl_num,
        WAC_PRICE_COPA_DATE  AS cal_month_start_dt,
        BASELINE_WAC_PRICE   AS actual_wac,
        CUST_PROD_CATEGORY,
        PREFERRED_SOURCE,
        EFFECTIVE_SOURCE
    FROM PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED
    WHERE COPA_NDC_NUM IS NOT NULL
      AND COPA_MTRL_NUM IS NOT NULL
      AND WAC_PRICE_COPA_DATE IS NOT NULL
      AND BASELINE_WAC_PRICE IS NOT NULL
      AND WAC_PRICE_COPA_DATE <= CURRENT_DATE()
),

collapsed AS (
    SELECT
        ndc_nmbr,
        mtrl_num,
        cal_month_start_dt,

        /* Keep one monthly WAC per ndc + material + month */
        MAX(actual_wac) AS actual_wac,

        /* Diagnostics */
        COUNT(*) AS src_row_cnt,
        COUNT(DISTINCT CUST_PROD_CATEGORY) AS distinct_category_cnt,
        MAX(PREFERRED_SOURCE) AS preferred_source,
        MAX(EFFECTIVE_SOURCE) AS effective_source
    FROM base
    GROUP BY 1,2,3
)

SELECT *
FROM collapsed
;

/* =====================================================================
   PATCH STEP 4: ACTUAL MONTHLY QTY
   - Rebuild uniquely at ndc + mtrl + month
   - Sum quantity once at that grain
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_QTY_MONTHLY AS
WITH copa_base AS (
    SELECT DISTINCT
        DATE_TRUNC('month', t_copa.POST_DT) AS cal_month_start_dt,
        t_copa.MTRL_NUM                     AS mtrl_num,
        mtrl.NDC_NMBR                       AS ndc_nmbr,
        t_copa.SLS_QTY_BEX,

        CASE
            WHEN t_copa.cmpny_cd = '8545' THEN
              CASE
                WHEN t_copa.PROD_HIER_1_NUM IN ('85451') THEN 'MPB Plasma'
                ELSE 'MPB Specialty'
              END
            WHEN t_copa.PROD_HIER_1_NUM IN ('00030','00050')
                 AND t_copa.sls_ctgry_cd NOT IN ('200','250','300','400','410','500','510') THEN 'OTC'
            WHEN t_copa.PROD_HIER_1_NUM = '00020' AND t_copa.cmpny_cd <> '8545' THEN 'GX'
            WHEN t_copa.SLS_CTGRY_CD IN ('102','103','106','107','112','116','122','123','701','703','711','806','807','816') THEN 'DROP SHIP'
            WHEN t_copa.MTRL_GRP2_CD = 'W2' THEN 'GLP-1'
            WHEN t_copa.MTRL_GRP2_CD IN ('R1', 'R2') THEN 'BIOSIMS'
            WHEN t_copa.MTRL_GRP2_CD IN ('V1', 'V2') THEN 'VAX'
            WHEN t_copa.MTRL_GRP2_CD IN ('S1','S3','S4','S5','S6') THEN 'APOLLO'
            ELSE 'BX'
        END AS cust_prod_category

    FROM PRD_MT_BIG_BETS_DB.POC.t_pharma_profitability_actuals_fpa_0525 t_copa

    LEFT JOIN (
        SELECT *
        FROM PRD_MT_BIG_BETS_DB.POC.t_material_pharma
        WHERE CURR_FLG = 'Y'
          AND ITM_CTVTY_CDE = 'A'
    ) mtrl
      ON t_copa.MTRL_NUM = mtrl.MATERIAL

    WHERE t_copa.WAC IS NOT NULL
      AND t_copa.WAC > 0
      AND t_copa.SLS_QTY_BEX IS NOT NULL
      AND t_copa.SLS_QTY_BEX > 0
),

filtered AS (
    SELECT *
    FROM copa_base
    WHERE cust_prod_category NOT IN ('GX', 'OTC')
      AND ndc_nmbr IS NOT NULL
),

collapsed AS (
    SELECT
        ndc_nmbr,
        mtrl_num,
        cal_month_start_dt,
        SUM(SLS_QTY_BEX) AS actual_qty,

        /* Diagnostics */
        COUNT(*) AS src_row_cnt,
        COUNT(DISTINCT cust_prod_category) AS distinct_category_cnt
    FROM filtered
    GROUP BY 1,2,3
)

SELECT *
FROM collapsed
;


/* ---------------------------------------------------------------------
   STEP 5: Historical panel available as-of each run
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST AS
SELECT
    r.run_id,
    r.jump_off_month,
    r.history_start_dt,
    r.history_end_dt,
    r.roll_1yr_start,
    r.roll_2yr_start,

    aw.ndc_nmbr,
    aw.mtrl_num,
    u.cust_prod_category,
    aw.actual_wac AS wac_price,
    aw.cal_month_start_dt

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY aw
JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUNS r
  ON aw.cal_month_start_dt >= r.history_start_dt
 AND aw.cal_month_start_dt <= r.history_end_dt
JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE u
  ON aw.ndc_nmbr = u.ndc_nmbr
 AND aw.mtrl_num = u.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 6: History age
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_AGE AS
SELECT
    run_id,
    mtrl_num,
    MIN(cal_month_start_dt) AS first_dt,
    MAX(cal_month_start_dt) AS last_dt,
    DATEDIFF('month', MIN(cal_month_start_dt), MAX(jump_off_month)) + 1 AS months_since_first
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST
GROUP BY run_id, mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 7: Last observed WAC
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_WAC AS
SELECT
    run_id,
    mtrl_num,
    MAX(cal_month_start_dt) AS last_hist_month,
    MAX_BY(wac_price, cal_month_start_dt) AS last_wac_price
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST
GROUP BY run_id, mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 8: Price changes
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES AS
SELECT
    z.*,
    CASE WHEN z.prev_price IS NOT NULL AND z.wac_price > z.prev_price THEN 1 ELSE 0 END AS increase_flag,
    CASE WHEN z.prev_price > 0 THEN (z.wac_price - z.prev_price) / z.prev_price END AS price_change_pct
FROM (
    SELECT
        h.*,
        LAG(wac_price) OVER (
            PARTITION BY run_id, mtrl_num
            ORDER BY cal_month_start_dt
        ) AS prev_price
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST h
) z
;


/* ---------------------------------------------------------------------
   STEP 9: Valid increase events
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_INCREASE_EVENTS AS
SELECT *
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES
WHERE increase_flag = 1
  AND price_change_pct IS NOT NULL
  AND price_change_pct >= 0.005
  AND price_change_pct < 5
;


/* ---------------------------------------------------------------------
   STEP 10: Last increase date
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_INCREASE AS
SELECT
    run_id,
    mtrl_num,
    MAX(cal_month_start_dt) AS last_increase_dt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_INCREASE_EVENTS
GROUP BY run_id, mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 11: NDC magnitude
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE AS
WITH full_events AS (
    SELECT
        run_id,
        mtrl_num,
        COUNT(*) AS ndc_full_events
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_INCREASE_EVENTS
    GROUP BY run_id, mtrl_num
),

events_2yr AS (
    SELECT
        fi.run_id,
        fi.mtrl_num,
        fi.price_change_pct,

        CASE WHEN fi.cal_month_start_dt >= fi.roll_1yr_start THEN 1 ELSE 0 END AS flag_1yr,
        CASE WHEN fi.cal_month_start_dt >= fi.roll_2yr_start
               AND fi.cal_month_start_dt < fi.roll_1yr_start THEN 1 ELSE 0 END AS flag_prev_1yr

    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_INCREASE_EVENTS fi
    WHERE fi.cal_month_start_dt >= fi.roll_2yr_start
),

agg AS (
    SELECT
        run_id,
        mtrl_num,
        MAX(flag_1yr) AS has_event_1yr,
        MAX(flag_prev_1yr) AS has_event_prev_1yr,
        COUNT(*) AS total_events_2yr,
        AVG(price_change_pct) AS avg_last_2yr_pi,
        AVG(CASE WHEN flag_1yr = 1 THEN price_change_pct END) AS avg_1yr_pi,
        AVG(CASE WHEN flag_prev_1yr = 1 THEN price_change_pct END) AS avg_prev_1yr_pi
    FROM events_2yr
    GROUP BY run_id, mtrl_num
)

SELECT
    COALESCE(a.run_id, f.run_id) AS run_id,
    COALESCE(a.mtrl_num, f.mtrl_num) AS mtrl_num,

    CASE
        WHEN has_event_1yr = 1 AND has_event_prev_1yr = 1
            THEN 0.6 * avg_1yr_pi + 0.4 * avg_prev_1yr_pi
        WHEN total_events_2yr >= 2
            THEN avg_last_2yr_pi
        WHEN total_events_2yr = 1
            THEN 0.5 * avg_last_2yr_pi
        ELSE 0
    END AS ndc_exp_wac_pi_pct,

    COALESCE(f.ndc_full_events, 0) AS ndc_full_events,
    COALESCE(a.total_events_2yr, 0) AS ndc_roll_events

FROM agg a
FULL OUTER JOIN full_events f
  ON a.run_id = f.run_id
 AND a.mtrl_num = f.mtrl_num
;


/* ---------------------------------------------------------------------
   STEP 12: NDC timing
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING AS
WITH gaps_all AS (
    SELECT
        run_id,
        mtrl_num,
        cal_month_start_dt,
        roll_1yr_start,
        roll_2yr_start,
        DATEDIFF(
            'day',
            LAG(cal_month_start_dt) OVER (
                PARTITION BY run_id, mtrl_num
                ORDER BY cal_month_start_dt
            ),
            cal_month_start_dt
        ) AS days_since_prev
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_INCREASE_EVENTS
),

gaps_clean AS (
    SELECT *
    FROM gaps_all
    WHERE days_since_prev IS NOT NULL
      AND days_since_prev > 0
),

gaps_2yr AS (
    SELECT
        run_id,
        mtrl_num,
        days_since_prev,
        CASE WHEN cal_month_start_dt >= roll_1yr_start THEN 1 ELSE 0 END AS flag_1yr,
        CASE WHEN cal_month_start_dt >= roll_2yr_start
               AND cal_month_start_dt < roll_1yr_start THEN 1 ELSE 0 END AS flag_prev_1yr
    FROM gaps_clean
    WHERE cal_month_start_dt >= roll_2yr_start
),

agg AS (
    SELECT
        run_id,
        mtrl_num,
        MAX(CASE WHEN flag_1yr = 1 THEN 1 ELSE 0 END) AS has_gap_1yr,
        MAX(CASE WHEN flag_prev_1yr = 1 THEN 1 ELSE 0 END) AS has_gap_prev_1yr,
        COUNT(*) AS total_gaps_2yr,
        AVG(days_since_prev) AS avg_last_2yr_gap,
        AVG(CASE WHEN flag_1yr = 1 THEN days_since_prev END) AS avg_1yr_gap,
        AVG(CASE WHEN flag_prev_1yr = 1 THEN days_since_prev END) AS avg_prev_1yr_gap
    FROM gaps_2yr
    GROUP BY run_id, mtrl_num
)

SELECT
    run_id,
    mtrl_num,
    CASE
        WHEN has_gap_1yr = 1 AND has_gap_prev_1yr = 1
            THEN 0.6 * avg_1yr_gap + 0.4 * avg_prev_1yr_gap
        WHEN total_gaps_2yr >= 1
            THEN avg_last_2yr_gap
        ELSE NULL
    END AS ndc_exp_days_between_increases,
    total_gaps_2yr AS ndc_roll_gap_ct
FROM agg
;


/* ---------------------------------------------------------------------
   STEP 13: Therapeutic fallback
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_THERAP_FALLBACK AS
WITH class_materials AS (
    SELECT DISTINCT
        ie.run_id,
        a.therapeutic_class,
        ie.mtrl_num
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_INCREASE_EVENTS ie
    JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP a
      ON ie.mtrl_num = a.mtrl_num
    WHERE a.therapeutic_class IS NOT NULL
),

material_level AS (
    SELECT
        cm.run_id,
        cm.therapeutic_class,
        cm.mtrl_num,
        nm.ndc_exp_wac_pi_pct,
        nt.ndc_exp_days_between_increases
    FROM class_materials cm
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE nm
      ON cm.run_id = nm.run_id
     AND cm.mtrl_num = nm.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING nt
      ON cm.run_id = nt.run_id
     AND cm.mtrl_num = nt.mtrl_num
)

SELECT
    run_id,
    therapeutic_class,
    AVG(ndc_exp_wac_pi_pct) AS therap_exp_wac_pi_pct,
    AVG(ndc_exp_days_between_increases) AS therap_exp_days_between_increases,
    COUNT(*) AS therap_material_cnt,
    COUNT(ndc_exp_wac_pi_pct) AS therap_material_cnt_with_pi,
    COUNT(ndc_exp_days_between_increases) AS therap_material_cnt_with_timing
FROM material_level
GROUP BY run_id, therapeutic_class
;


/* ---------------------------------------------------------------------
   STEP 14: Manufacturer fallback
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MFR_FALLBACK AS
WITH mfr_materials AS (
    SELECT DISTINCT
        ie.run_id,
        a.manufacturer_name,
        ie.mtrl_num
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_INCREASE_EVENTS ie
    JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP a
      ON ie.mtrl_num = a.mtrl_num
    WHERE a.manufacturer_name IS NOT NULL
),

material_level AS (
    SELECT
        mm.run_id,
        mm.manufacturer_name,
        mm.mtrl_num,
        nm.ndc_exp_wac_pi_pct,
        nt.ndc_exp_days_between_increases
    FROM mfr_materials mm
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE nm
      ON mm.run_id = nm.run_id
     AND mm.mtrl_num = nm.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING nt
      ON mm.run_id = nt.run_id
     AND mm.mtrl_num = nt.mtrl_num
)

SELECT
    run_id,
    manufacturer_name,
    AVG(ndc_exp_wac_pi_pct) AS mfr_exp_wac_pi_pct,
    AVG(ndc_exp_days_between_increases) AS mfr_exp_days_between_increases,
    COUNT(*) AS mfr_material_cnt,
    COUNT(ndc_exp_wac_pi_pct) AS mfr_material_cnt_with_pi,
    COUNT(ndc_exp_days_between_increases) AS mfr_material_cnt_with_timing
FROM material_level
GROUP BY run_id, manufacturer_name
;


/* =====================================================================
   STEP 15: BASELINE RESOLVED
   - One row per run_id + ndc + mtrl
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED AS
WITH base AS (
    SELECT
        r.run_id,
        r.jump_off_month,

        u.ndc_nmbr,
        u.mtrl_num,
        u.cust_prod_category,

        a.therapeutic_class,
        a.sell_dscr,
        a.THRPTC_CLSS_CDE,
        a.THERA_CLS_DSCR,
        a.manufacturer_name,
        a.BYNG_DESC,
        a.ITM_CTVTY_CDE,
        a.MTRL_CURR_FLG,

        COALESCE(h.months_since_first, 0) AS months_since_first,
        CASE WHEN COALESCE(h.months_since_first, 0) >= 12 THEN 1 ELSE 0 END AS has_12m_history,

        COALESCE(nm.ndc_full_events, 0) AS ndc_full_events,
        CASE WHEN COALESCE(nm.ndc_full_events, 0) = 0 THEN 1 ELSE 0 END AS never_increased_flag,

        CASE WHEN tf.therap_exp_wac_pi_pct IS NOT NULL THEN 1 ELSE 0 END AS has_therap_fallback,
        CASE WHEN mf.mfr_exp_wac_pi_pct IS NOT NULL THEN 1 ELSE 0 END AS has_manufacturer_fallback,

        CASE
            WHEN COALESCE(h.months_since_first, 0) >= 12
                 AND COALESCE(nm.ndc_full_events, 0) = 0
                THEN 'NO_MEANINGFUL_INCREASE'
            WHEN COALESCE(h.months_since_first, 0) >= 12
                 AND COALESCE(nm.ndc_full_events, 0) > 0
                THEN 'NDC'
            WHEN COALESCE(h.months_since_first, 0) < 12
                 AND tf.therap_exp_wac_pi_pct IS NOT NULL
                THEN 'THERAP_CLASS'
            WHEN COALESCE(h.months_since_first, 0) < 12
                 AND tf.therap_exp_wac_pi_pct IS NULL
                 AND mf.mfr_exp_wac_pi_pct IS NOT NULL
                THEN 'MANUFACTURER'
            ELSE 'NO_FALLBACK_AVAILABLE'
        END AS forecast_source_level,

        CASE
            WHEN COALESCE(h.months_since_first, 0) >= 12
                 AND COALESCE(nm.ndc_full_events, 0) = 0
                THEN 0
            WHEN COALESCE(h.months_since_first, 0) >= 12
                 AND COALESCE(nm.ndc_full_events, 0) > 0
                THEN nm.ndc_exp_wac_pi_pct
            WHEN COALESCE(h.months_since_first, 0) < 12
                 AND tf.therap_exp_wac_pi_pct IS NOT NULL
                THEN tf.therap_exp_wac_pi_pct
            WHEN COALESCE(h.months_since_first, 0) < 12
                 AND tf.therap_exp_wac_pi_pct IS NULL
                 AND mf.mfr_exp_wac_pi_pct IS NOT NULL
                THEN mf.mfr_exp_wac_pi_pct
            ELSE 0
        END AS expected_wac_pi_pct,

        CASE
            WHEN COALESCE(h.months_since_first, 0) >= 12
                 AND COALESCE(nm.ndc_full_events, 0) > 0
                THEN nt.ndc_exp_days_between_increases
            WHEN COALESCE(h.months_since_first, 0) < 12
                 AND tf.therap_exp_days_between_increases IS NOT NULL
                THEN tf.therap_exp_days_between_increases
            WHEN COALESCE(h.months_since_first, 0) < 12
                 AND tf.therap_exp_days_between_increases IS NULL
                 AND mf.mfr_exp_days_between_increases IS NOT NULL
                THEN mf.mfr_exp_days_between_increases
            ELSE NULL
        END AS expected_days_between_increases

    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUNS r

    CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE u

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP a
      ON u.ndc_nmbr = a.ndc_nmbr
     AND u.mtrl_num = a.mtrl_num

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_AGE h
      ON r.run_id = h.run_id
     AND u.mtrl_num = h.mtrl_num

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE nm
      ON r.run_id = nm.run_id
     AND u.mtrl_num = nm.mtrl_num

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING nt
      ON r.run_id = nt.run_id
     AND u.mtrl_num = nt.mtrl_num

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_THERAP_FALLBACK tf
      ON r.run_id = tf.run_id
     AND a.therapeutic_class = tf.therapeutic_class

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MFR_FALLBACK mf
      ON r.run_id = mf.run_id
     AND a.manufacturer_name = mf.manufacturer_name
),

ranked AS (
    SELECT
        base.*,
        ROW_NUMBER() OVER (
            PARTITION BY run_id, ndc_nmbr, mtrl_num
            ORDER BY
                CASE forecast_source_level
                    WHEN 'NDC' THEN 1
                    WHEN 'THERAP_CLASS' THEN 2
                    WHEN 'MANUFACTURER' THEN 3
                    WHEN 'NO_MEANINGFUL_INCREASE' THEN 4
                    ELSE 5
                END,
                months_since_first DESC
        ) AS rn
    FROM base
)

SELECT
    run_id,
    jump_off_month,
    ndc_nmbr,
    mtrl_num,
    cust_prod_category,
    therapeutic_class,
    sell_dscr,
    THRPTC_CLSS_CDE,
    THERA_CLS_DSCR,
    manufacturer_name,
    BYNG_DESC,
    ITM_CTVTY_CDE,
    MTRL_CURR_FLG,
    months_since_first,
    has_12m_history,
    ndc_full_events,
    never_increased_flag,
    has_therap_fallback,
    has_manufacturer_fallback,
    forecast_source_level,
    expected_wac_pi_pct,
    expected_days_between_increases
FROM ranked
WHERE rn = 1
;


/* =====================================================================
   STEP 16: FUTURE ACTUAL MONTHS
   - Use >= jump_off_month so jump-off month is included in evaluation
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FUTURE_ACTUAL_MONTHS AS
SELECT DISTINCT
    r.run_id,
    r.jump_off_month,
    aw.ndc_nmbr,
    aw.mtrl_num,
    aw.cal_month_start_dt AS forecast_month
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUNS r
JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY aw
  ON aw.cal_month_start_dt >= r.jump_off_month
JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE u
  ON aw.ndc_nmbr = u.ndc_nmbr
 AND aw.mtrl_num = u.mtrl_num
;


/* =====================================================================
   STEP 17: FORECASTED
   - One row per run_id + ndc + mtrl + forecast_month
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED AS
WITH base AS (
    SELECT
        br.run_id,
        br.jump_off_month,
        br.ndc_nmbr,
        br.mtrl_num,
        br.cust_prod_category,
        br.sell_dscr,
        br.therapeutic_class,
        br.manufacturer_name,
        br.forecast_source_level,
        br.expected_wac_pi_pct,
        br.expected_days_between_increases,

        lw.last_hist_month,
        lw.last_wac_price,
        li.last_increase_dt,

        fam.forecast_month,

        DATEDIFF(
            'day',
            COALESCE(li.last_increase_dt, br.jump_off_month),
            fam.forecast_month
        ) AS days_since_ref

    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED br

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_WAC lw
      ON br.run_id = lw.run_id
     AND br.mtrl_num = lw.mtrl_num

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_INCREASE li
      ON br.run_id = li.run_id
     AND br.mtrl_num = li.mtrl_num

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FUTURE_ACTUAL_MONTHS fam
      ON br.run_id = fam.run_id
     AND br.ndc_nmbr = fam.ndc_nmbr
     AND br.mtrl_num = fam.mtrl_num
),

calc AS (
    SELECT
        *,
        CASE
            WHEN forecast_month IS NULL THEN NULL
            WHEN forecast_source_level IN ('NO_MEANINGFUL_INCREASE', 'NO_FALLBACK_AVAILABLE')
              OR expected_wac_pi_pct <= 0
              OR expected_days_between_increases IS NULL
              OR expected_days_between_increases <= 0
            THEN 0
            ELSE FLOOR(days_since_ref / expected_days_between_increases)
        END AS n_expected_increases
    FROM base
),

ranked AS (
    SELECT
        calc.*,
        ROW_NUMBER() OVER (
            PARTITION BY run_id, ndc_nmbr, mtrl_num, forecast_month
            ORDER BY last_hist_month DESC
        ) AS rn
    FROM calc
)

SELECT
    run_id,
    jump_off_month,
    ndc_nmbr,
    mtrl_num,
    cust_prod_category,
    sell_dscr,
    therapeutic_class,
    manufacturer_name,
    forecast_source_level,
    expected_wac_pi_pct,
    expected_days_between_increases,
    last_hist_month,
    last_wac_price,
    last_increase_dt,
    forecast_month,
    days_since_ref,
    n_expected_increases,

    CASE
        WHEN forecast_month IS NULL THEN NULL
        WHEN last_wac_price IS NULL THEN NULL
        WHEN forecast_source_level IN ('NO_MEANINGFUL_INCREASE', 'NO_FALLBACK_AVAILABLE')
          OR expected_wac_pi_pct <= 0
          OR expected_days_between_increases IS NULL
          OR expected_days_between_increases <= 0
        THEN last_wac_price
        ELSE last_wac_price * POWER(
            1 + expected_wac_pi_pct,
            n_expected_increases
        )
    END AS forecasted_wac

FROM ranked
WHERE rn = 1
  AND forecast_month IS NOT NULL
;


/* =====================================================================
   STEP 18: RESULTS
   - One row per run_id + ndc + mtrl + forecast_month
   - Add low-WAC and explosion flags
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RESULTS AS
WITH base AS (
    SELECT
        f.run_id,
        f.jump_off_month,
        f.ndc_nmbr,
        f.mtrl_num,
        f.cust_prod_category,
        f.sell_dscr,
        f.therapeutic_class,
        f.manufacturer_name,
        f.forecast_source_level,
        f.last_hist_month,
        f.last_wac_price,
        f.last_increase_dt,
        f.expected_wac_pi_pct,
        f.expected_days_between_increases,
        f.forecast_month,
        DATEDIFF('month', f.jump_off_month, f.forecast_month) AS months_ahead,
        f.days_since_ref,
        f.n_expected_increases,
        f.forecasted_wac,

        aw.actual_wac,
        aq.actual_qty,

        f.forecasted_wac * aq.actual_qty AS forecasted_dollars,
        aw.actual_wac * aq.actual_qty    AS actual_dollars
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED f

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY aw
      ON f.ndc_nmbr       = aw.ndc_nmbr
     AND f.mtrl_num       = aw.mtrl_num
     AND f.forecast_month = aw.cal_month_start_dt

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_QTY_MONTHLY aq
      ON f.ndc_nmbr       = aq.ndc_nmbr
     AND f.mtrl_num       = aq.mtrl_num
     AND f.forecast_month = aq.cal_month_start_dt
),

ranked AS (
    SELECT
        base.*,
        ROW_NUMBER() OVER (
            PARTITION BY run_id, ndc_nmbr, mtrl_num, forecast_month
            ORDER BY forecast_month
        ) AS rn
    FROM base
)

SELECT
    run_id,
    jump_off_month,
    ndc_nmbr,
    mtrl_num,
    cust_prod_category,
    sell_dscr,
    therapeutic_class,
    manufacturer_name,
    forecast_source_level,
    last_hist_month,
    last_wac_price,
    last_increase_dt,
    expected_wac_pi_pct,
    expected_days_between_increases,
    forecast_month,
    months_ahead,
    days_since_ref,
    n_expected_increases,
    forecasted_wac,
    actual_wac,
    actual_qty,
    forecasted_dollars,
    actual_dollars,

    /* Core error metrics */
    forecasted_wac - actual_wac AS wac_error,
    ABS(forecasted_wac - actual_wac) AS abs_wac_error,

    CASE
        WHEN actual_wac IS NOT NULL AND actual_wac <> 0
        THEN ABS(forecasted_wac - actual_wac) / ABS(actual_wac)
        ELSE NULL
    END AS wac_ape,

    forecasted_dollars - actual_dollars AS dollar_error,
    ABS(forecasted_dollars - actual_dollars) AS abs_dollar_error,

    CASE
        WHEN actual_dollars IS NOT NULL AND actual_dollars <> 0
        THEN ABS(forecasted_dollars - actual_dollars) / ABS(actual_dollars)
        ELSE NULL
    END AS dollar_ape,

    /* Diagnostics */
    CASE WHEN actual_wac <= 1 THEN 1 ELSE 0 END AS low_actual_wac_flag,

    CASE
        WHEN expected_wac_pi_pct > 0.20 THEN 1
        WHEN expected_days_between_increases IS NOT NULL AND expected_days_between_increases < 60 THEN 1
        WHEN n_expected_increases > 12 THEN 1
        WHEN forecasted_wac IS NOT NULL
         AND last_wac_price IS NOT NULL
         AND forecasted_wac > last_wac_price * 10 THEN 1
        ELSE 0
    END AS forecast_explosion_flag

FROM ranked
WHERE rn = 1
;


/* =====================================================================
   STEP 19: DASHBOARD
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD AS
WITH base AS (
    SELECT
        *,

        CASE
            WHEN months_ahead <= 3 THEN '0_3M'
            WHEN months_ahead <= 6 THEN '4_6M'
            WHEN months_ahead <= 12 THEN '7_12M'
            ELSE '12M_PLUS'
        END AS horizon_bucket,

        CASE
            WHEN actual_wac IS NULL OR last_wac_price IS NULL THEN NULL
            WHEN (actual_wac - last_wac_price) * (forecasted_wac - last_wac_price) >= 0
                THEN 1
            ELSE 0
        END AS direction_correct_flag,

        CASE
            WHEN wac_ape IS NULL THEN NULL
            WHEN wac_ape <= 0.05 THEN 'GOOD'
            WHEN wac_ape <= 0.15 THEN 'OK'
            ELSE 'BAD'
        END AS wac_error_band,

        CASE
            WHEN dollar_ape IS NULL THEN NULL
            WHEN dollar_ape <= 0.05 THEN 'GOOD'
            WHEN dollar_ape <= 0.15 THEN 'OK'
            ELSE 'BAD'
        END AS dollar_error_band,

        CASE
            WHEN abs_dollar_error IS NULL THEN 0
            WHEN abs_dollar_error > 50000 THEN 1
            ELSE 0
        END AS big_dollar_miss_flag

    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RESULTS
),

scored AS (
    SELECT
        base.*,

        SUM(abs_dollar_error) OVER (PARTITION BY run_id) AS total_abs_error_run,

        CASE
            WHEN SUM(abs_dollar_error) OVER (PARTITION BY run_id) > 0
            THEN abs_dollar_error /
                 SUM(abs_dollar_error) OVER (PARTITION BY run_id)
            ELSE NULL
        END AS dollar_error_weight,

        ROW_NUMBER() OVER (
            PARTITION BY run_id
            ORDER BY abs_dollar_error DESC, ndc_nmbr, mtrl_num, forecast_month
        ) AS error_row_num

    FROM base
)

SELECT *
FROM scored
;


/* =====================================================================
   STEP 20: CLEAN DASHBOARD
   - Remove low-WAC actuals
   - Remove obvious explosion rows from primary KPI reporting
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN AS
SELECT *
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD
WHERE actual_wac > 1
  AND forecasted_wac IS NOT NULL
  AND actual_qty IS NOT NULL
  AND forecast_explosion_flag = 0
;

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
--5,476

/* =====================================================================
   QC QUERIES
   - Run these and send screenshots
   ===================================================================== */

/* ---------------------------------------------------------------------
QC-1: Confirm actual WAC monthly uniqueness
Expected: 0 rows
--------------------------------------------------------------------- */
SELECT
    ndc_nmbr, mtrl_num, cal_month_start_dt, COUNT(*) AS cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY
GROUP BY 1,2,3
HAVING COUNT(*) > 1
ORDER BY cnt DESC
;


/* ---------------------------------------------------------------------
QC-2: Confirm actual QTY monthly uniqueness
Expected: 0 rows
--------------------------------------------------------------------- */
SELECT
    ndc_nmbr, mtrl_num, cal_month_start_dt, COUNT(*) AS cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_QTY_MONTHLY
GROUP BY 1,2,3
HAVING COUNT(*) > 1
ORDER BY cnt DESC
;


/* ---------------------------------------------------------------------
QC-3: Confirm forecasted uniqueness
Expected: 0 rows
--------------------------------------------------------------------- */
SELECT
    run_id, ndc_nmbr, mtrl_num, forecast_month, COUNT(*) AS cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED
GROUP BY 1,2,3,4
HAVING COUNT(*) > 1
ORDER BY cnt DESC
;


/* ---------------------------------------------------------------------
QC-4: Confirm results uniqueness
Expected: 0 rows
--------------------------------------------------------------------- */
SELECT
    run_id, ndc_nmbr, mtrl_num, forecast_month, COUNT(*) AS cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RESULTS
GROUP BY 1,2,3,4
HAVING COUNT(*) > 1
ORDER BY cnt DESC
;


/* ---------------------------------------------------------------------
QC-5: Actual WAC distribution
Check low-WAC issue
--------------------------------------------------------------------- */
SELECT
    run_id,
    MIN(actual_wac) AS min_actual_wac,
    PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY actual_wac) AS p01_actual_wac,
    PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY actual_wac) AS p05_actual_wac,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY actual_wac) AS median_actual_wac
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RESULTS
GROUP BY 1
ORDER BY 1
;


/* ---------------------------------------------------------------------
QC-6: Actual quantity distribution
Check quantity scale
--------------------------------------------------------------------- */
SELECT
    run_id,
    MIN(actual_qty) AS min_qty,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY actual_qty) AS median_qty,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY actual_qty) AS p95_qty,
    MAX(actual_qty) AS max_qty
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RESULTS
GROUP BY 1
ORDER BY 1
;


/* ---------------------------------------------------------------------
QC-7: Explosion flag counts
Expected: ideally low
--------------------------------------------------------------------- */
SELECT
    run_id,
    forecast_explosion_flag,
    COUNT(*) AS row_cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RESULTS
GROUP BY 1,2
ORDER BY 1,2
;


/* ---------------------------------------------------------------------
QC-8: Worst explosion rows
Please screenshot top 25
--------------------------------------------------------------------- */
SELECT
    run_id,
    ndc_nmbr,
    mtrl_num,
    forecast_month,
    expected_wac_pi_pct,
    expected_days_between_increases,
    n_expected_increases,
    last_wac_price,
    forecasted_wac,
    actual_wac,
    wac_ape
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RESULTS
WHERE forecast_explosion_flag = 1
ORDER BY wac_ape DESC
LIMIT 25
;


/* ---------------------------------------------------------------------
QC-9: Raw WAPE summary (before clean filter)
--------------------------------------------------------------------- */
SELECT
    run_id,
    SUM(ABS(forecasted_dollars - actual_dollars))
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS dollar_wape,
    SUM(ABS(forecasted_wac - actual_wac))
      / NULLIF(SUM(ABS(actual_wac)), 0) AS wac_wape
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD
GROUP BY 1
ORDER BY 1
;


/* ---------------------------------------------------------------------
QC-10: Clean WAPE summary (after low-WAC + explosion filter)
--------------------------------------------------------------------- */
SELECT
    run_id,
    COUNT(*) AS rows_used,
    SUM(ABS(forecasted_dollars - actual_dollars))
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS dollar_wape,
    SUM(ABS(forecasted_wac - actual_wac))
      / NULLIF(SUM(ABS(actual_wac)), 0) AS wac_wape
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
GROUP BY 1
ORDER BY 1
;


/* ---------------------------------------------------------------------
QC-11: Dashboard summary by forecast source (clean)
--------------------------------------------------------------------- */
SELECT
    run_id,
    forecast_source_level,
    COUNT(*) AS rows_used,
    AVG(wac_ape) AS avg_wac_ape,
    AVG(dollar_ape) AS avg_dollar_ape,
    SUM(abs_dollar_error) AS total_abs_dollar_error
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
GROUP BY 1,2
ORDER BY 1, total_abs_dollar_error DESC
;


/* ---------------------------------------------------------------------
QC-12: Dashboard summary by horizon bucket (clean)
--------------------------------------------------------------------- */
SELECT
    run_id,
    horizon_bucket,
    COUNT(*) AS rows_used,
    AVG(wac_ape) AS avg_wac_ape,
    AVG(dollar_ape) AS avg_dollar_ape,
    SUM(abs_dollar_error) AS total_abs_dollar_error
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
GROUP BY 1,2
ORDER BY 1,2
;


/* ---------------------------------------------------------------------
QC-13: Top 25 biggest clean misses by dollar error
--------------------------------------------------------------------- */
SELECT
    run_id,
    ndc_nmbr,
    mtrl_num,
    forecast_month,
    forecast_source_level,
    actual_wac,
    forecasted_wac,
    actual_qty,
    actual_dollars,
    forecasted_dollars,
    abs_dollar_error,
    wac_ape,
    dollar_ape
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY run_id
    ORDER BY abs_dollar_error DESC
) <= 25
ORDER BY run_id, abs_dollar_error DESC
;

--Qc-14
SELECT
    run_id,
    COUNT(*) AS total_rows,

    AVG(CASE WHEN wac_ape <= 0.03 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_3,
    AVG(CASE WHEN wac_ape <= 0.05 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_5,
    AVG(CASE WHEN wac_ape <= 0.07 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_7,
    AVG(CASE WHEN wac_ape <= 0.10 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_10,

    AVG(CASE WHEN dollar_ape <= 0.03 THEN 1 ELSE 0 END) AS pct_rows_dollar_ape_le_3,
    AVG(CASE WHEN dollar_ape <= 0.05 THEN 1 ELSE 0 END) AS pct_rows_dollar_ape_le_5,
    AVG(CASE WHEN dollar_ape <= 0.07 THEN 1 ELSE 0 END) AS pct_rows_dollar_ape_le_7,
    AVG(CASE WHEN dollar_ape <= 0.10 THEN 1 ELSE 0 END) AS pct_rows_dollar_ape_le_10

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
GROUP BY 1
ORDER BY 1;

--QC-15
SELECT
    run_id,
    SUM(ABS(actual_dollars)) AS total_actual_dollars,

    SUM(CASE WHEN wac_ape <= 0.03 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_wac_ape_le_3,

    SUM(CASE WHEN wac_ape <= 0.05 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_wac_ape_le_5,

    SUM(CASE WHEN wac_ape <= 0.07 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_wac_ape_le_7,

    SUM(CASE WHEN wac_ape <= 0.10 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_wac_ape_le_10,

    SUM(CASE WHEN dollar_ape <= 0.03 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_dollar_ape_le_3,

    SUM(CASE WHEN dollar_ape <= 0.05 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_dollar_ape_le_5,

    SUM(CASE WHEN dollar_ape <= 0.07 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_dollar_ape_le_7,

    SUM(CASE WHEN dollar_ape <= 0.10 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_dollar_ape_le_10

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
GROUP BY 1
ORDER BY 1;


--QC-16 -- HORIZON Bucket (Reveals that short tem forecasts are strong)
SELECT
    run_id,
    horizon_bucket,
    COUNT(*) AS total_rows,

    AVG(CASE WHEN wac_ape <= 0.05 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_5,
    AVG(CASE WHEN wac_ape <= 0.07 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_7,

    SUM(CASE WHEN wac_ape <= 0.05 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_wac_ape_le_5,

    SUM(CASE WHEN wac_ape <= 0.07 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_wac_ape_le_7

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
GROUP BY 1,2
ORDER BY 1,2;


--QC-17
SELECT
    run_id,
    forecast_source_level,
    COUNT(*) AS total_rows,

    AVG(CASE WHEN wac_ape <= 0.05 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_5,
    AVG(CASE WHEN wac_ape <= 0.07 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_7,

    SUM(CASE WHEN wac_ape <= 0.05 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_wac_ape_le_5,

    SUM(CASE WHEN wac_ape <= 0.07 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_wac_ape_le_7

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
GROUP BY 1,2
ORDER BY 1,2;

--QC-18
SELECT
    run_id,
    COUNT(*) AS total_rows,

    AVG(CASE WHEN wac_ape <= 0.05 THEN 1 ELSE 0 END) AS pct_rows_within_5pct,
    AVG(CASE WHEN wac_ape <= 0.07 THEN 1 ELSE 0 END) AS pct_rows_within_7pct,

    SUM(CASE WHEN wac_ape <= 0.05 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_within_5pct,

    SUM(CASE WHEN wac_ape <= 0.07 THEN ABS(actual_dollars) ELSE 0 END)
      / NULLIF(SUM(ABS(actual_dollars)), 0) AS pct_dollars_within_7pct

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
GROUP BY 1
ORDER BY 1;


--QC-19
/* =====================================================================
   STEP A: Revenue deciles by run_id + forecast_month
   - Uses ACTUAL revenue at material level
   - Revenue definition = actual_wac * actual_qty
   - Deciles are created within each run_id + forecast_month
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_REVENUE_DECILES AS
WITH base AS (
    SELECT
        run_id,
        forecast_month,
        ndc_nmbr,
        mtrl_num,
        actual_wac,
        actual_qty,
        actual_dollars AS actual_revenue
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
    WHERE actual_dollars IS NOT NULL
      AND actual_dollars > 0
),

ranked AS (
    SELECT
        *,
        NTILE(10) OVER (
            PARTITION BY run_id, forecast_month
            ORDER BY actual_revenue DESC
        ) AS revenue_decile_desc
    FROM base
)

SELECT
    run_id,
    forecast_month,
    ndc_nmbr,
    mtrl_num,
    actual_revenue,

    /* Decile label:
       1 = top revenue decile
       10 = lowest revenue decile
    */
    revenue_decile_desc AS revenue_decile,

    CASE
        WHEN revenue_decile_desc = 1 THEN 'D01_TOP'
        WHEN revenue_decile_desc = 2 THEN 'D02'
        WHEN revenue_decile_desc = 3 THEN 'D03'
        WHEN revenue_decile_desc = 4 THEN 'D04'
        WHEN revenue_decile_desc = 5 THEN 'D05'
        WHEN revenue_decile_desc = 6 THEN 'D06'
        WHEN revenue_decile_desc = 7 THEN 'D07'
        WHEN revenue_decile_desc = 8 THEN 'D08'
        WHEN revenue_decile_desc = 9 THEN 'D09'
        WHEN revenue_decile_desc = 10 THEN 'D10_BOTTOM'
    END AS revenue_decile_label

FROM ranked
;



WITH base AS (
    SELECT
        run_id,
        forecast_month,
        ndc_nmbr,
        mtrl_num,
        actual_wac,
        actual_qty,
        actual_dollars AS actual_revenue
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN
    WHERE actual_dollars IS NOT NULL
      AND actual_dollars > 0
),

ranked AS (
    SELECT
        *,
        NTILE(10) OVER (
            PARTITION BY run_id, forecast_month
            ORDER BY actual_revenue DESC
        ) AS revenue_decile_desc
    FROM base
)

select sum(actual_revenue) from base;


/* =====================================================================
   STEP B: Dashboard clean + revenue decile
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN_DECILE AS
SELECT
    d.*,
    r.revenue_decile,
    r.revenue_decile_label
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN d
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_REVENUE_DECILES r
  ON d.run_id = r.run_id
 AND d.forecast_month = r.forecast_month
 AND d.ndc_nmbr = r.ndc_nmbr
 AND d.mtrl_num = r.mtrl_num
;


--QC-20
/* =====================================================================
   STEP C: Performance summary by revenue decile
   ===================================================================== */

SELECT
    run_id,
    revenue_decile_label,
    COUNT(*) AS total_rows,

    AVG(CASE WHEN wac_ape <= 0.03 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_3,
    AVG(CASE WHEN wac_ape <= 0.05 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_5,
    AVG(CASE WHEN wac_ape <= 0.07 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_7,
    AVG(CASE WHEN wac_ape <= 0.10 THEN 1 ELSE 0 END) AS pct_rows_wac_ape_le_10,

    AVG(CASE WHEN dollar_ape <= 0.03 THEN 1 ELSE 0 END) AS pct_rows_dollar_ape_le_3,
    AVG(CASE WHEN dollar_ape <= 0.05 THEN 1 ELSE 0 END) AS pct_rows_dollar_ape_le_5,
    AVG(CASE WHEN dollar_ape <= 0.07 THEN 1 ELSE 0 END) AS pct_rows_dollar_ape_le_7,
    AVG(CASE WHEN dollar_ape <= 0.10 THEN 1 ELSE 0 END) AS pct_rows_dollar_ape_le_10,

    SUM(actual_dollars) AS total_actual_dollars,
    SUM(abs_dollar_error) AS total_abs_dollar_error

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN_DECILE
GROUP BY 1, 2
ORDER BY 1, 2
;


/* =====================================================================
   STEP D: Crosstab example
   - WAC APE <= 5% by revenue decile
   ===================================================================== */

SELECT
    run_id,

    AVG(CASE WHEN revenue_decile = 1  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d01_top,
    AVG(CASE WHEN revenue_decile = 2  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d02,
    AVG(CASE WHEN revenue_decile = 3  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d03,
    AVG(CASE WHEN revenue_decile = 4  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d04,
    AVG(CASE WHEN revenue_decile = 5  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d05,
    AVG(CASE WHEN revenue_decile = 6  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d06,
    AVG(CASE WHEN revenue_decile = 7  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d07,
    AVG(CASE WHEN revenue_decile = 8  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d08,
    AVG(CASE WHEN revenue_decile = 9  AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d09,
    AVG(CASE WHEN revenue_decile = 10 AND wac_ape <= 0.05 THEN 1 ELSE 0 END) AS d10_bottom

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_DASHBOARD_CLEAN_DECILE
GROUP BY 1
ORDER BY 1
;


SELECT
    run_id,
    forecast_month,
    revenue_decile,
    COUNT(*) AS row_cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_REVENUE_DECILES
GROUP BY 1,2,3
ORDER BY 1,2,3
LIMIT 100;
