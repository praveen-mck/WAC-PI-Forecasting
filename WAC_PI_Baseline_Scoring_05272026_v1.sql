
   -- STRATEGY for Baseline:
   ==========================================================================================================================================
   -- 0. Summary:Identify rolling avg. for Prince increase magnitude and rolling avg. for days between price increases. Rollback window = 2 years. Weights: LY = 0.6 and PLY = 0.4.
   -- 1. Check material tenure 
   -- 2. If < 12 months, consider as new material
   -- 3. Use therapeutic class as first fallback
   -- 4. Use manufacturer as second fallback
   ==========================================================================================================================================

/* =====================================================================
   WAC PI Baseline Forecast (V2) — Rolling Weighted + 5-Year Projection
   ---------------------------------------------------------------------
   INPUT TABLES:
     - COPA WAC history: PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_COPA_NDC_V2
     - Vendor source: PRD_MT_BIG_BETS_DB.POC.t_material_pharma
     - Manufacturer map: PRD_MT_BIG_BETS_DB.POC.t_manufacturer_pharma ( JOIN using vendor variable from t_material_pharma ON vendor_id from Manufacturer table)
     - Therapeutic class (THERAPEUTIC_CLASS), SELL_DSCR: "PRD_PSAS_DB"."RPT"."T_DM_VSTX_ITEM"
     - Therapeutic class code (THRPTC_CLSS_CDE): PRD_MT_BIG_BETS_DB.POC.t_material_pharma
     - Therapeutic class description (THERA_CLS_DSCR): "PRD_PSAS_DB"."RPT"."T_AHFS_THERA_CLS"

   OUTPUT TABLE:
     - DEV_MT_BIG_BETS_DB.POC.WAC_PI_BASELINE_FORECAST_5YR_V3
       (one row per item per month for next 60 months)
   ===================================================================== */
   
/* =====================================================================
   WAC PI Baseline Forecast (Modular Build)
   =====================================================================

   IMPORTANT MODEL / DATA DECISIONS

   1) Universe / scope
      - Score ALL materials in the NDC universe.
      - DO NOT exclude cust_prod_category = 'DROP SHIP'.

   2) Attribute sourcing
      - Material master:
          PRD_MT_BIG_BETS_DB.POC.t_material_pharma
          Fields used:
            MATERIAL
            VENDOR
            THRPTC_CLSS_CDE
            BYNG_DESC
            ITM_CTVTY_CDE
            CURR_FLG
      - Manufacturer map:
          PRD_MT_BIG_BETS_DB.POC.t_manufacturer_pharma
          Join:
            t_material_pharma.VENDOR = t_manufacturer_pharma.VENDOR_ID
      - Therapeutic class + SELL_DSCR:
          PRD_PSAS_DB.RPT.T_DM_VSTX_ITEM using EM_ITEM_NUM
      - AHFS description:
          PRD_PSAS_DB.RPT.T_AHFS_THERA_CLS using plain cleaned code equality

   3) Join rules
      - Universe -> material master:
            u.mtrl_num = m.MATERIAL
      - Universe -> VSTX:
            TRY_TO_NUMBER(u.mtrl_num) = v.EM_ITEM_NUM
      - TRY_TO_NUMBER is ONLY used for the VSTX join.

   4) History / eligibility
      - months_since_first uses ANY available history before the cutoff date
        (not first meaningful increase).
      - Purpose: determine whether the item has >=12 months of usable history span.

   5) Latest WAC price
      - Keep ALL datapoints before the cutoff date for latest price selection.
      - Do NOT require min WAC price to determine latest WAC.

   6) Meaningful increase events for modeling
      - Only treat an increase as valid if:
            price_change_pct >= 0.005  (>= 0.5%)
            price_change_pct <  5      (< 500%)
      - Used for:
            item-level magnitude
            item-level timing
            therapeutic fallback
            manufacturer fallback

   7) Fall-off / evaluation flags
      - Final scoring is anchored on the full universe, so items do not disappear.
      - Flags explain why an item does not participate fully in:
            attribute enrichment
            usable history build
            valid increase-event modeling
            fallback logic

   8) Monthly -> quarterly helper columns
      - Final output includes:
            forecast_quarter_start_dt
            forecast_year
            forecast_quarter_num
            forecast_year_quarter
            month_in_quarter
            is_quarter_end_month
            forecast_quarter_end_dt
      - These help convert monthly forecasts into quarterly forecasts.

   OUTPUT TABLE:
      DEV_MT_BIG_BETS_DB.POC.WAC_PI_BASELINE_FORECAST_5YR_V2
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: Parameters
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS AS
SELECT
    12     AS MIN_HISTORY_MONTHS,   -- "established" threshold
    1      AS MIN_WAC_PRICE,        -- filter for modeling base only
    5      AS MAX_CHANGE_PCT,       -- outlier cutoff: >=500%
    0.005  AS MIN_CHANGE_PCT,       -- meaningful increase cutoff: >=0.5%

    DATE_TRUNC('month', CURRENT_DATE())                     AS ANCHOR_MONTH_START,
    DATEADD(day, -1, DATE_TRUNC('month', CURRENT_DATE()))   AS HISTORY_END_DT,
    DATEADD(year, -1, DATE_TRUNC('month', CURRENT_DATE()))  AS ROLL_1YR_START,
    DATEADD(year, -2, DATE_TRUNC('month', CURRENT_DATE()))  AS ROLL_2YR_START
;


select * from PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ITEMS_UNIVERSE 

/* ---------------------------------------------------------------------
   STEP 1: Universe
   - Keep DROP SHIP in scope
   - Retain explicit invalid/test NDC exclusions
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ITEMS_UNIVERSE AS
SELECT DISTINCT
    COPA_NDC_NUM       AS ndc_nmbr,
    COPA_MTRL_NUM      AS mtrl_num,
    CUST_PROD_CATEGORY AS cust_prod_category
FROM PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED
WHERE COPA_NDC_NUM NOT IN (
        '00000000000','00000000001','00000000002','00000000003',
        '00000000004','00000000005','00000000009','00000000010',
        '00000000069','00000000091'
)
AND LENGTH(COPA_NDC_NUM) > 0
;

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ITEMS_UNIVERSE

/* ---------------------------------------------------------------------
   STEP 2: Attributes
   - Plain join to material master
   - TRY_TO_NUMBER used only for VSTX join
   - Add ITM_CTVTY_CDE and CURR_FLG from material master
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS AS
WITH
mtrl AS (
    SELECT
        MATERIAL,
        VENDOR,
        THRPTC_CLSS_CDE,
        BYNG_DESC,
        ITM_CTVTY_CDE,
        CURR_FLG,
        NULLIF(TRIM(TO_VARCHAR(THRPTC_CLSS_CDE)), '') AS THRPTC_CLSS_CDE_CLEAN
    FROM PRD_MT_BIG_BETS_DB.POC.t_material_pharma
    WHERE CURR_FLG = 'Y'
),
mfr AS (
    SELECT
        VENDOR_ID,
        MFG_NAME AS MANUFACTURER_NAME
    FROM PRD_MT_BIG_BETS_DB.POC.t_manufacturer_pharma
    WHERE CURR_FLG = 'Y'
),
/* Deduplicate VSTX on EM_ITEM_NUM */
vstx AS (
    SELECT
        EM_ITEM_NUM,
        THERAPEUTIC_CLASS,
        SELL_DSCR
    FROM PRD_PSAS_DB.RPT.T_DM_VSTX_ITEM
    WHERE EM_ITEM_NUM IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY EM_ITEM_NUM
        ORDER BY EM_ITEM_NUM
    ) = 1
),
/* Deduplicate AHFS on cleaned code */
ahfs AS (
    SELECT
        NULLIF(TRIM(TO_VARCHAR(THERA_CLS_CD)), '') AS THERA_CLS_CD_CLEAN,
        THERA_CLS_CD,
        THERA_CLS_DSCR
    FROM PRD_PSAS_DB.RPT.T_AHFS_THERA_CLS
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY NULLIF(TRIM(TO_VARCHAR(THERA_CLS_CD)), '')
        ORDER BY UPDT_DTS DESC
    ) = 1
)
SELECT
    u.ndc_nmbr,
    u.mtrl_num,
    u.cust_prod_category,

    /* Material master fields */
    m.THRPTC_CLSS_CDE,
    m.BYNG_DESC,
    m.ITM_CTVTY_CDE,
    m.CURR_FLG AS MTRL_CURR_FLG,

    /* VSTX fields */
    v.THERAPEUTIC_CLASS AS therapeutic_class,
    v.SELL_DSCR         AS sell_dscr,

    /* AHFS field */
    a.THERA_CLS_DSCR,

    /* Manufacturer field */
    mf.MANUFACTURER_NAME AS manufacturer_name,

    /* Coverage flags at attribute level */
    CASE WHEN m.MATERIAL IS NOT NULL THEN 1 ELSE 0 END AS has_material_match,
    CASE WHEN v.EM_ITEM_NUM IS NOT NULL THEN 1 ELSE 0 END AS has_vstx_match,
    CASE WHEN mf.MANUFACTURER_NAME IS NOT NULL THEN 1 ELSE 0 END AS has_manufacturer_match,
    CASE WHEN a.THERA_CLS_DSCR IS NOT NULL THEN 1 ELSE 0 END AS has_ahfs_match

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ITEMS_UNIVERSE u
LEFT JOIN mtrl m
    ON u.mtrl_num = m.MATERIAL
LEFT JOIN mfr mf
    ON m.VENDOR = mf.VENDOR_ID
LEFT JOIN vstx v
    ON TRY_TO_NUMBER(u.mtrl_num) = v.EM_ITEM_NUM
LEFT JOIN ahfs a
    ON m.THRPTC_CLSS_CDE_CLEAN = a.THERA_CLS_CD_CLEAN
;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY order by mtrl_num, cal_month_start_dt

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY

select * from PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED


--Check for duplicates
SELECT
    mtrl_num,
    cal_month_start_dt,
    COUNT(*) AS cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY
GROUP BY 1,2
HAVING COUNT(*) > 1;

select is_deduped, count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY group by 1

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY order by mtrl_num, cal_month_start_dt



SELECT *
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY
WHERE wac_price IS NULL
LIMIT 20;



SELECT MIN(cal_month_start_dt), MAX(cal_month_start_dt)
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY;


SELECT
    COUNT(*) AS raw_rows,
    COUNT(DISTINCT mtrl_num) AS raw_materials,
    COUNT(DISTINCT cal_month_start_dt) AS raw_months
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY;


SELECT
    COUNT(*) AS base_rows,
    COUNT(DISTINCT mtrl_num) AS base_materials,
    COUNT(DISTINCT cal_month_start_dt) AS base_months
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASE;

/* ---------------------------------------------------------------------
   STEP 3: Raw history panel
   - ALL history rows (no MIN_WAC filter)
   - Used for:
       * history coverage flags
       * latest WAC price selection
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY AS

/* --------------------------------------------------
   Step 1: Base data
-------------------------------------------------- */
WITH base AS (
    SELECT
        x.COPA_NDC_NUM        AS ndc_nmbr,
        x.COPA_MTRL_NUM       AS mtrl_num,
        x.CUST_PROD_CATEGORY  AS cust_prod_category,

        x.BASELINE_WAC_PRICE  AS wac_price,
        x.WAC_PRICE_COPA_DATE AS cal_month_start_dt,

        YEAR(x.WAC_PRICE_COPA_DATE)  AS cal_year,
        MONTH(x.WAC_PRICE_COPA_DATE) AS cal_month,

        x.PREFERRED_SOURCE,
        x.EFFECTIVE_SOURCE

    FROM PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED x
),

/* --------------------------------------------------
   Step 2: Count duplicates
-------------------------------------------------- */
tagged AS (
    SELECT
        b.*,
        COUNT(*) OVER (
            PARTITION BY mtrl_num, cal_month_start_dt
        ) AS dup_cnt
    FROM base b
),

/* --------------------------------------------------
   Step 3: Dedup
-------------------------------------------------- */
dedup AS (
    SELECT *
    FROM (
        SELECT
            t.*,
            ROW_NUMBER() OVER (
                PARTITION BY mtrl_num, cal_month_start_dt
                ORDER BY 
                    CASE 
                        WHEN PREFERRED_SOURCE = EFFECTIVE_SOURCE THEN 1 
                        ELSE 2 
                    END,
                    PREFERRED_SOURCE,
                    EFFECTIVE_SOURCE
            ) AS rn
        FROM tagged t
    )
    WHERE rn = 1
),

/* --------------------------------------------------
   Step 4: Dedup universe (CRITICAL FIX)
-------------------------------------------------- */
universe_clean AS (
    SELECT DISTINCT mtrl_num
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ITEMS_UNIVERSE
)

/* --------------------------------------------------
   Step 5: Final output
-------------------------------------------------- */
SELECT
    d.ndc_nmbr,
    d.mtrl_num,
    d.cust_prod_category,
    d.wac_price,
    d.cal_month_start_dt,
    d.cal_year,
    d.cal_month,

    /* flags */
    d.dup_cnt,
    CASE WHEN d.dup_cnt > 1 THEN 1 ELSE 0 END AS is_deduped,

    d.PREFERRED_SOURCE,
    d.EFFECTIVE_SOURCE

FROM dedup d

JOIN universe_clean u
  ON d.mtrl_num = u.mtrl_num
;

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_UNIVERSE_STATUS

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_UNIVERSE_STATUS
--6896

/* ---------------------------------------------------------------------
   STEP 4: Universe status / fall-off reasons
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_UNIVERSE_STATUS AS
SELECT
    u.ndc_nmbr,
    u.mtrl_num,

    COUNT(rh.cal_month_start_dt) AS raw_history_row_cnt,

    COUNT(CASE
        WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT THEN 1
    END) AS history_before_cutoff_row_cnt,

    COUNT(CASE
        WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT
         AND rh.wac_price > p.MIN_WAC_PRICE THEN 1
    END) AS usable_base_row_cnt,

    COUNT(CASE
        WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT
         AND rh.wac_price <= p.MIN_WAC_PRICE THEN 1
    END) AS low_price_before_cutoff_row_cnt,

    COUNT(CASE
        WHEN rh.cal_month_start_dt > p.HISTORY_END_DT THEN 1
    END) AS after_cutoff_row_cnt,

    /* Coverage flags */
    CASE WHEN COUNT(rh.cal_month_start_dt) > 0 THEN 1 ELSE 0 END AS has_any_raw_history,
    CASE WHEN COUNT(CASE WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT THEN 1 END) > 0 THEN 1 ELSE 0 END AS has_history_before_cutoff,
    CASE WHEN COUNT(CASE
                    WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT
                     AND rh.wac_price > p.MIN_WAC_PRICE THEN 1
              END) > 0
         THEN 1 ELSE 0 END AS has_usable_base_history,

    /* Fall-off reason flags */
    CASE
        WHEN COUNT(CASE WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT THEN 1 END) = 0
        THEN 1 ELSE 0
    END AS flag_no_history_before_cutoff,

    CASE
        WHEN COUNT(CASE WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT THEN 1 END) > 0
         AND COUNT(CASE
                    WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT
                     AND rh.wac_price > p.MIN_WAC_PRICE THEN 1
              END) = 0
        THEN 1 ELSE 0
    END AS flag_only_low_price_history_before_cutoff,

    CASE
        WHEN COUNT(CASE WHEN rh.cal_month_start_dt > p.HISTORY_END_DT THEN 1 END) > 0
         AND COUNT(CASE WHEN rh.cal_month_start_dt <= p.HISTORY_END_DT THEN 1 END) = 0
        THEN 1 ELSE 0
    END AS flag_history_only_after_cutoff

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ITEMS_UNIVERSE u
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY rh
  ON u.ndc_nmbr = rh.ndc_nmbr
 AND u.mtrl_num = rh.mtrl_num
CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
GROUP BY
    u.ndc_nmbr,
    u.mtrl_num
;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASE order by mtrl_num, cal_month_start_dt

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASE
--6745

/* ---------------------------------------------------------------------
   STEP 5: Modeling base history
   - Rows before cutoff and above MIN_WAC_PRICE
   - LEFT JOIN attrs so rows are retained even if enrichment is missing
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASE AS
SELECT
    rh.ndc_nmbr,
    rh.mtrl_num,
    rh.cust_prod_category,

    /* Attributes (can be NULL if enrichment missing) */
    a.therapeutic_class,
    a.sell_dscr,
    a.THRPTC_CLSS_CDE,
    a.THERA_CLS_DSCR,
    a.manufacturer_name,
    a.BYNG_DESC,
    a.ITM_CTVTY_CDE,
    a.MTRL_CURR_FLG,
    a.has_material_match,
    a.has_vstx_match,
    a.has_manufacturer_match,
    a.has_ahfs_match,

    rh.wac_price,
    rh.cal_year,
    rh.cal_month,
    rh.cal_month_start_dt

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY rh
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS a
  ON rh.ndc_nmbr = a.ndc_nmbr
 AND rh.mtrl_num = a.mtrl_num
CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
WHERE rh.wac_price > p.MIN_WAC_PRICE
  AND rh.cal_month_start_dt <= p.HISTORY_END_DT
;



select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PRICE_CHANGES order by mtrl_num, cal_month_start_dt

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PRICE_CHANGES
--6745

/* ---------------------------------------------------------------------
   STEP 6: Price changes on modeling base
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PRICE_CHANGES AS
SELECT
    z.*,
    CASE WHEN z.prev_price IS NOT NULL AND z.wac_price > z.prev_price THEN 1 ELSE 0 END AS increase_flag,
    CASE WHEN z.prev_price > 0 THEN (z.wac_price - z.prev_price) / z.prev_price END AS price_change_pct
FROM (
    SELECT
        b.*,
        LAG(wac_price) OVER (PARTITION BY mtrl_num ORDER BY cal_month_start_dt) AS prev_price
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASE b
) z
;



select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_OUTLIER_STATS

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_OUTLIER_STATS
--6745

/* ---------------------------------------------------------------------
   STEP 7A: Outlier stats
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_OUTLIER_STATS AS
SELECT
    pc.mtrl_num,

    COUNT(CASE
        WHEN pc.increase_flag = 1
         AND pc.price_change_pct IS NOT NULL
         AND pc.price_change_pct < p.MIN_CHANGE_PCT
        THEN 1 END) AS low_outlier_cnt,

    COUNT(CASE
        WHEN pc.increase_flag = 1
         AND pc.price_change_pct IS NOT NULL
         AND pc.price_change_pct >= p.MAX_CHANGE_PCT
        THEN 1 END) AS high_outlier_cnt,

    CASE WHEN COUNT(CASE
            WHEN pc.increase_flag = 1
             AND pc.price_change_pct IS NOT NULL
             AND pc.price_change_pct < p.MIN_CHANGE_PCT
        THEN 1 END) > 0
        THEN 1 ELSE 0 END AS has_low_outliers,

    CASE WHEN COUNT(CASE
            WHEN pc.increase_flag = 1
             AND pc.price_change_pct IS NOT NULL
             AND pc.price_change_pct >= p.MAX_CHANGE_PCT
        THEN 1 END) > 0
        THEN 1 ELSE 0 END AS has_high_outliers

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PRICE_CHANGES pc
CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
GROUP BY pc.mtrl_num
;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_INCREASE_EVENTS

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_INCREASE_EVENTS
--4404
/* ---------------------------------------------------------------------
   STEP 7B: Valid increase events
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_INCREASE_EVENTS AS
SELECT pc.*
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PRICE_CHANGES pc
CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
WHERE pc.increase_flag = 1
  AND pc.price_change_pct IS NOT NULL
  AND pc.price_change_pct >= p.MIN_CHANGE_PCT
  AND pc.price_change_pct <  p.MAX_CHANGE_PCT
;



select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY
--6896
select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_HISTORY

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_HISTORY
--6862

/* ---------------------------------------------------------------------
   STEP 8: History table
   - Based on ANY available history before cutoff (raw history)
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_HISTORY AS
SELECT
    rh.mtrl_num,
    MIN(rh.cal_month_start_dt) AS first_dt,
    MAX(rh.cal_month_start_dt) AS last_dt,
    DATEDIFF('month', MIN(rh.cal_month_start_dt), p.ANCHOR_MONTH_START) + 1 AS months_since_first
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY rh
CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
WHERE rh.cal_month_start_dt <= p.HISTORY_END_DT
GROUP BY rh.mtrl_num, p.ANCHOR_MONTH_START
;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_MAGNITUDE

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_MAGNITUDE
--4,404 IDs

/* ---------------------------------------------------------------------
   STEP 9: NDC magnitude
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_MAGNITUDE AS

/* ✅ Full history event count (needed downstream) */
WITH full_events AS (
    SELECT
        mtrl_num,
        COUNT(*) AS ndc_full_events
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_INCREASE_EVENTS
    GROUP BY mtrl_num
),

/* ✅ Last 2-year events */
events_2yr AS (
    SELECT
        fi.mtrl_num,

        CASE 
            WHEN fi.cal_month_start_dt >= p.ROLL_1YR_START THEN 1 ELSE 0 
        END AS flag_1yr,

        CASE 
            WHEN fi.cal_month_start_dt >= p.ROLL_2YR_START 
             AND fi.cal_month_start_dt < p.ROLL_1YR_START THEN 1 ELSE 0 
        END AS flag_prev_1yr,

        fi.price_change_pct

    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_INCREASE_EVENTS fi
    CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
    WHERE fi.cal_month_start_dt >= p.ROLL_2YR_START
),

agg AS (
    SELECT
        mtrl_num,

        MAX(flag_1yr) AS has_event_1yr,
        MAX(flag_prev_1yr) AS has_event_prev_1yr,
        COUNT(*) AS total_events_2yr,

        AVG(price_change_pct) AS avg_last_2yr_pi,
        AVG(CASE WHEN flag_1yr = 1 THEN price_change_pct END) AS avg_1yr_pi,
        AVG(CASE WHEN flag_prev_1yr = 1 THEN price_change_pct END) AS avg_prev_1yr_pi

    FROM events_2yr
    GROUP BY mtrl_num
)

SELECT
    COALESCE(a.mtrl_num, f.mtrl_num) AS mtrl_num,

    /* ✅ MAGNITUDE LOGIC */
    CASE

        WHEN has_event_1yr = 1 AND has_event_prev_1yr = 1
            THEN 0.6 * avg_1yr_pi + 0.4 * avg_prev_1yr_pi

        WHEN total_events_2yr >= 2
            THEN avg_last_2yr_pi

        WHEN total_events_2yr = 1
            THEN 0.5 * avg_last_2yr_pi

        ELSE 0

    END AS ndc_exp_wac_pi_pct,

    /* ✅ Required downstream */
    COALESCE(f.ndc_full_events, 0) AS ndc_full_events,

    /* ✅ Optional but useful */
    COALESCE(a.total_events_2yr, 0) AS ndc_roll_events

FROM agg a
FULL OUTER JOIN full_events f
    ON a.mtrl_num = f.mtrl_num
;


select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_TIMING 
--2958
select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_TIMING

/* ---------------------------------------------------------------------
   STEP 10: NDC timing
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_TIMING AS
WITH gaps_all AS (
    SELECT
        mtrl_num,
        cal_month_start_dt,
        DATEDIFF(
            'day',
            LAG(cal_month_start_dt) OVER (
                PARTITION BY mtrl_num
                ORDER BY cal_month_start_dt
            ),
            cal_month_start_dt
        ) AS days_since_prev
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_INCREASE_EVENTS
),

gaps_clean AS (
    SELECT *
    FROM gaps_all
    WHERE days_since_prev IS NOT NULL
      AND days_since_prev > 0
),

gaps_2yr AS (
    SELECT
        g.mtrl_num,

        CASE
            WHEN g.cal_month_start_dt >= p.ROLL_1YR_START THEN 1 ELSE 0
        END AS flag_1yr,

        CASE
            WHEN g.cal_month_start_dt >= p.ROLL_2YR_START
             AND g.cal_month_start_dt < p.ROLL_1YR_START THEN 1 ELSE 0
        END AS flag_prev_1yr,

        g.days_since_prev
    FROM gaps_clean g
    CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
    WHERE g.cal_month_start_dt >= p.ROLL_2YR_START
),

agg AS (
    SELECT
        mtrl_num,

        /* consistency signals */
        MAX(flag_1yr) AS has_gap_1yr,
        MAX(flag_prev_1yr) AS has_gap_prev_1yr,

        /* total recent gaps */
        COUNT(*) AS total_gaps_2yr,

        /* simple avg across last 2 yrs */
        AVG(days_since_prev) AS avg_last_2yr_gap,

        /* period-specific averages */
        AVG(CASE WHEN flag_1yr = 1 THEN days_since_prev END) AS avg_1yr_gap,
        AVG(CASE WHEN flag_prev_1yr = 1 THEN days_since_prev END) AS avg_prev_1yr_gap

    FROM gaps_2yr
    GROUP BY mtrl_num
),

final_calc AS (
    SELECT
        mtrl_num,

        /* weighted only when both periods have signal */
        (0.6 * avg_1yr_gap + 0.4 * avg_prev_1yr_gap) AS roll_wtd_days_between,

        avg_last_2yr_gap,
        total_gaps_2yr,
        has_gap_1yr,
        has_gap_prev_1yr

    FROM agg
)

SELECT
    mtrl_num,

    CASE
        /* consistent recent cadence */
        WHEN has_gap_1yr = 1 AND has_gap_prev_1yr = 1
            THEN roll_wtd_days_between

        /* some recent cadence, but not consistent */
        WHEN total_gaps_2yr >= 1
            THEN avg_last_2yr_gap

        /* no recent signal */
        ELSE NULL
    END AS ndc_exp_days_between_increases,

    total_gaps_2yr AS ndc_roll_gap_ct

FROM final_calc;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_THERAP_FALLBACK

select count(distinct therapeutic_class) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_THERAP_FALLBACK

/* ---------------------------------------------------------------------
   STEP 11: Therapeutic fallback
   CORRECTED LOGIC:
   - Do NOT compute timing gaps directly across all events within a class
   - Instead:
       1) Use material-level magnitude estimate from WAC_PI_BF_NDC_MAGNITUDE
       2) Use material-level timing estimate from WAC_PI_BF_NDC_TIMING
       3) Aggregate those material-level estimates to therapeutic class
   - This gives the average behavior of materials in the class,
     not the event frequency across the class.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_THERAP_FALLBACK AS
WITH class_materials AS (
    SELECT DISTINCT
        mtrl_num,
        therapeutic_class
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS
    WHERE therapeutic_class IS NOT NULL
),

material_level AS (
    SELECT
        cm.therapeutic_class,
        cm.mtrl_num,
        nm.ndc_exp_wac_pi_pct,
        nt.ndc_exp_days_between_increases
    FROM class_materials cm
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_MAGNITUDE nm
        ON cm.mtrl_num = nm.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_TIMING nt
        ON cm.mtrl_num = nt.mtrl_num
)

SELECT
    therapeutic_class,

    /* Average of material-level expected PI% within class */
    AVG(ndc_exp_wac_pi_pct) AS therap_exp_wac_pi_pct,

    /* Average of material-level expected days-between within class */
    AVG(ndc_exp_days_between_increases) AS therap_exp_days_between_increases,

    /* Helpful diagnostics */
    COUNT(*) AS therap_material_cnt,
    COUNT(ndc_exp_wac_pi_pct) AS therap_material_cnt_with_pi,
    COUNT(ndc_exp_days_between_increases) AS therap_material_cnt_with_timing

FROM material_level
GROUP BY therapeutic_class
;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_MFR_FALLBACK

select count(distinct manufacturer_name) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_MFR_FALLBACK


/* ---------------------------------------------------------------------
   STEP 12: Manufacturer fallback
   CORRECTED LOGIC:
   - Use material-level magnitude + timing estimates
   - Aggregate those to manufacturer level
   - Avoid computing gaps across all manufacturer events
   --------------------------------------------------------------------- */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_MFR_FALLBACK AS

WITH mfr_materials AS (
    SELECT DISTINCT
        mtrl_num,
        manufacturer_name
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS
    WHERE manufacturer_name IS NOT NULL
),

material_level AS (
    SELECT
        mm.manufacturer_name,
        mm.mtrl_num,

        /* Material-level magnitude */
        nm.ndc_exp_wac_pi_pct,

        /* Material-level timing */
        nt.ndc_exp_days_between_increases

    FROM mfr_materials mm

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_MAGNITUDE nm
        ON mm.mtrl_num = nm.mtrl_num

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_TIMING nt
        ON mm.mtrl_num = nt.mtrl_num
)

SELECT
    manufacturer_name,

    /* ✅ Magnitude: average of material-level PI */
    AVG(ndc_exp_wac_pi_pct) AS mfr_exp_wac_pi_pct,

    /* ✅ Timing: average of material-level gaps */
    AVG(ndc_exp_days_between_increases) AS mfr_exp_days_between_increases,

    /* ✅ Diagnostics (VERY useful for QA) */
    COUNT(*) AS mfr_material_cnt,
    COUNT(ndc_exp_wac_pi_pct) AS mfr_material_cnt_with_pi,
    COUNT(ndc_exp_days_between_increases) AS mfr_material_cnt_with_timing

FROM material_level

GROUP BY manufacturer_name;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_LAST_WAC

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_LAST_WAC

/* ---------------------------------------------------------------------
   STEP 13: Last observed WAC
   - Use ALL datapoints before cutoff
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_LAST_WAC AS
SELECT
    rh.mtrl_num,
    MAX(rh.cal_month_start_dt) AS last_hist_month,
    MAX_BY(rh.wac_price, rh.cal_month_start_dt) AS last_wac_price
FROM 
    DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_RAW_HISTORY rh
CROSS JOIN 
    DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
WHERE 
    rh.cal_month_start_dt <= p.HISTORY_END_DT
GROUP BY 
    rh.mtrl_num
;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_LAST_INCREASE

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_LAST_INCREASE
--4404
/* ---------------------------------------------------------------------
   STEP 14: Last valid increase date
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_LAST_INCREASE AS
SELECT
    mtrl_num,
    MAX(cal_month_start_dt) AS last_increase_dt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_INCREASE_EVENTS
GROUP BY mtrl_num
;

DESC TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_MAGNITUDE;

Select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASELINE_RESOLVED

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASELINE_RESOLVED
--6896

/* ---------------------------------------------------------------------
   STEP 15: Per-item baseline resolution
   - ANCHORED ON FULL UNIVERSE
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASELINE_RESOLVED AS
SELECT
    u.ndc_nmbr,
    u.mtrl_num,
    u.cust_prod_category,

    /* Attributes */
    a.therapeutic_class,
    a.sell_dscr,
    a.THRPTC_CLSS_CDE,
    a.THERA_CLS_DSCR,
    a.manufacturer_name,
    a.BYNG_DESC,
    a.ITM_CTVTY_CDE,
    a.MTRL_CURR_FLG,

    /* Attribute coverage */
    COALESCE(a.has_material_match, 0)      AS has_material_match,
    COALESCE(a.has_vstx_match, 0)          AS has_vstx_match,
    COALESCE(a.has_manufacturer_match, 0)  AS has_manufacturer_match,
    COALESCE(a.has_ahfs_match, 0)          AS has_ahfs_match,

    /* History coverage / fall-off */
    COALESCE(us.raw_history_row_cnt, 0)              AS raw_history_row_cnt,
    COALESCE(us.history_before_cutoff_row_cnt, 0)    AS history_before_cutoff_row_cnt,
    COALESCE(us.usable_base_row_cnt, 0)              AS usable_base_row_cnt,
    COALESCE(us.low_price_before_cutoff_row_cnt, 0)  AS low_price_before_cutoff_row_cnt,
    COALESCE(us.after_cutoff_row_cnt, 0)             AS after_cutoff_row_cnt,

    COALESCE(us.has_any_raw_history, 0)         AS has_any_raw_history,
    COALESCE(us.has_history_before_cutoff, 0)   AS has_history_before_cutoff,
    COALESCE(us.has_usable_base_history, 0)     AS has_usable_base_history,

    COALESCE(us.flag_no_history_before_cutoff, 0)             AS flag_no_history_before_cutoff,
    COALESCE(us.flag_only_low_price_history_before_cutoff, 0) AS flag_only_low_price_history_before_cutoff,
    COALESCE(us.flag_history_only_after_cutoff, 0)            AS flag_history_only_after_cutoff,

    /* History age */
    COALESCE(h.months_since_first, 0) AS months_since_first,

    CASE 
        WHEN COALESCE(h.months_since_first, 0) >= p.MIN_HISTORY_MONTHS THEN 1 
        ELSE 0 
    END AS has_12m_history,

    /* Event / outlier stats */
    COALESCE(nm.ndc_full_events, 0) AS ndc_full_events,

    COALESCE(os.low_outlier_cnt, 0) AS low_outlier_cnt,
    COALESCE(os.high_outlier_cnt, 0) AS high_outlier_cnt,
    COALESCE(os.has_low_outliers, 0) AS has_low_outliers,
    COALESCE(os.has_high_outliers, 0) AS has_high_outliers,

    CASE 
        WHEN COALESCE(nm.ndc_full_events, 0) = 0 THEN 1 
        ELSE 0 
    END AS never_increased_flag,

    /* Fallback availability */
    CASE 
        WHEN tf.therap_exp_wac_pi_pct IS NOT NULL THEN 1 
        ELSE 0 
    END AS has_therap_fallback,

    CASE 
        WHEN mf.mfr_exp_wac_pi_pct IS NOT NULL THEN 1 
        ELSE 0 
    END AS has_manufacturer_fallback,

    /* -------------------------------
       Forecast source routing
       ------------------------------- */
    CASE
        WHEN COALESCE(h.months_since_first, 0) >= p.MIN_HISTORY_MONTHS
             AND COALESCE(nm.ndc_full_events, 0) = 0
            THEN 'NO_MEANINGFUL_INCREASE'

        WHEN COALESCE(h.months_since_first, 0) >= p.MIN_HISTORY_MONTHS
             AND COALESCE(nm.ndc_full_events, 0) > 0
            THEN 'NDC'

        WHEN COALESCE(h.months_since_first, 0) < p.MIN_HISTORY_MONTHS
             AND tf.therap_exp_wac_pi_pct IS NOT NULL
            THEN 'THERAP_CLASS'

        WHEN COALESCE(h.months_since_first, 0) < p.MIN_HISTORY_MONTHS
             AND tf.therap_exp_wac_pi_pct IS NULL
             AND mf.mfr_exp_wac_pi_pct IS NOT NULL
            THEN 'MANUFACTURER'

        ELSE 'NO_FALLBACK_AVAILABLE'
    END AS forecast_source_level,

    /* -------------------------------
       Expected magnitude
       ------------------------------- */
    CASE
        WHEN COALESCE(h.months_since_first, 0) >= p.MIN_HISTORY_MONTHS
             AND COALESCE(nm.ndc_full_events, 0) = 0
            THEN 0

        WHEN COALESCE(h.months_since_first, 0) >= p.MIN_HISTORY_MONTHS
             AND COALESCE(nm.ndc_full_events, 0) > 0
            THEN nm.ndc_exp_wac_pi_pct

        WHEN COALESCE(h.months_since_first, 0) < p.MIN_HISTORY_MONTHS
             AND tf.therap_exp_wac_pi_pct IS NOT NULL
            THEN tf.therap_exp_wac_pi_pct

        WHEN COALESCE(h.months_since_first, 0) < p.MIN_HISTORY_MONTHS
             AND tf.therap_exp_wac_pi_pct IS NULL
             AND mf.mfr_exp_wac_pi_pct IS NOT NULL
            THEN mf.mfr_exp_wac_pi_pct

        ELSE 0
    END AS expected_wac_pi_pct,

    /* -------------------------------
       Expected cadence
       ------------------------------- */
    CASE
        WHEN COALESCE(h.months_since_first, 0) >= p.MIN_HISTORY_MONTHS
             AND COALESCE(nm.ndc_full_events, 0) > 0
            THEN nt.ndc_exp_days_between_increases

        WHEN COALESCE(h.months_since_first, 0) < p.MIN_HISTORY_MONTHS
             AND tf.therap_exp_days_between_increases IS NOT NULL
            THEN tf.therap_exp_days_between_increases

        WHEN COALESCE(h.months_since_first, 0) < p.MIN_HISTORY_MONTHS
             AND tf.therap_exp_days_between_increases IS NULL
             AND mf.mfr_exp_days_between_increases IS NOT NULL
            THEN mf.mfr_exp_days_between_increases

        ELSE NULL
    END AS expected_days_between_increases

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ITEMS_UNIVERSE u

LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS a
    ON u.ndc_nmbr = a.ndc_nmbr
   AND u.mtrl_num = a.mtrl_num

LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_UNIVERSE_STATUS us
    ON u.ndc_nmbr = us.ndc_nmbr
   AND u.mtrl_num = us.mtrl_num

LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_HISTORY h
    ON u.mtrl_num = h.mtrl_num

LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_MAGNITUDE nm
    ON u.mtrl_num = nm.mtrl_num

LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_NDC_TIMING nt
    ON u.mtrl_num = nt.mtrl_num

LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_THERAP_FALLBACK tf
    ON a.therapeutic_class = tf.therapeutic_class

LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_MFR_FALLBACK mf
    ON a.manufacturer_name = mf.manufacturer_name

LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_OUTLIER_STATS os
    ON u.mtrl_num = os.mtrl_num

CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
;

/* ---------------------------------------------------------------------
   STEP 16: Future months
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_FUTURE_MONTHS AS
SELECT
    DATEADD(month, seq4(), p.ANCHOR_MONTH_START) AS forecast_month
FROM 
    TABLE(GENERATOR(ROWCOUNT => 60))
CROSS JOIN 
    DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
;


select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BASELINE_FORECAST_5YR_V2
--6896

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BASELINE_FORECAST_5YR_V2

/* ---------------------------------------------------------------------
   STEP 17: Final forecast output
   - Includes quarterly helper columns
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BASELINE_FORECAST_5YR_V2 AS
SELECT
    br.ndc_nmbr,
    br.mtrl_num,
    br.cust_prod_category,

    br.sell_dscr,
    br.therapeutic_class,
    br.THRPTC_CLSS_CDE,
    br.THERA_CLS_DSCR,
    br.manufacturer_name,
    br.BYNG_DESC,
    br.ITM_CTVTY_CDE,
    br.MTRL_CURR_FLG,

    /* Evaluation / QA */
    br.has_material_match,
    br.has_vstx_match,
    br.has_manufacturer_match,
    br.has_ahfs_match,

    br.raw_history_row_cnt,
    br.history_before_cutoff_row_cnt,
    br.usable_base_row_cnt,
    br.low_price_before_cutoff_row_cnt,
    br.after_cutoff_row_cnt,

    br.has_any_raw_history,
    br.has_history_before_cutoff,
    br.has_usable_base_history,

    br.flag_no_history_before_cutoff,
    br.flag_only_low_price_history_before_cutoff,
    br.flag_history_only_after_cutoff,

    br.months_since_first,
    br.has_12m_history,
    br.ndc_full_events,
    br.never_increased_flag,
    br.has_therap_fallback,
    br.has_manufacturer_fallback,
    br.forecast_source_level,

    br.low_outlier_cnt,
    br.high_outlier_cnt,
    br.has_low_outliers,
    br.has_high_outliers,

    lw.last_hist_month,
    lw.last_wac_price,
    li.last_increase_dt,

    br.expected_wac_pi_pct,
    br.expected_days_between_increases,

    /* Monthly forecast calendar */
    fm.forecast_month,

    /* Quarterly helper columns */
    DATE_TRUNC('quarter', fm.forecast_month) AS forecast_quarter_start_dt,
    YEAR(fm.forecast_month) AS forecast_year,
    QUARTER(fm.forecast_month) AS forecast_quarter_num,
    TO_VARCHAR(YEAR(fm.forecast_month)) || '-Q' || TO_VARCHAR(QUARTER(fm.forecast_month)) AS forecast_year_quarter,
    MOD(MONTH(fm.forecast_month) - 1, 3) + 1 AS month_in_quarter,
    CASE WHEN MONTH(fm.forecast_month) IN (3, 6, 9, 12) THEN 1 ELSE 0 END AS is_quarter_end_month,
    DATEADD(month, 2, DATE_TRUNC('quarter', fm.forecast_month)) AS forecast_quarter_end_dt,

    DATEDIFF(
        'day',
        COALESCE(li.last_increase_dt, p.ANCHOR_MONTH_START),
        fm.forecast_month
    ) AS days_since_ref,

    CASE
        WHEN br.forecast_source_level IN ('NO_MEANINGFUL_INCREASE', 'NO_FALLBACK_AVAILABLE')
          OR br.expected_wac_pi_pct <= 0
          OR br.expected_days_between_increases IS NULL
          OR br.expected_days_between_increases <= 0
        THEN 0
        ELSE FLOOR(
            DATEDIFF(
                'day',
                COALESCE(li.last_increase_dt, p.ANCHOR_MONTH_START),
                fm.forecast_month
            ) / br.expected_days_between_increases
        )
    END AS n_expected_increases,

    CASE
        WHEN lw.last_wac_price IS NULL THEN NULL
        WHEN br.forecast_source_level IN ('NO_MEANINGFUL_INCREASE', 'NO_FALLBACK_AVAILABLE')
          OR br.expected_wac_pi_pct <= 0
          OR br.expected_days_between_increases IS NULL
          OR br.expected_days_between_increases <= 0
        THEN lw.last_wac_price
        ELSE lw.last_wac_price * POWER(
            1 + br.expected_wac_pi_pct,
            FLOOR(
                DATEDIFF(
                    'day',
                    COALESCE(li.last_increase_dt, p.ANCHOR_MONTH_START),
                    fm.forecast_month
                ) / br.expected_days_between_increases
            )
        )
    END AS forecast_wac_price

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_BASELINE_RESOLVED br
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_LAST_WAC lw
    ON br.mtrl_num = lw.mtrl_num
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_LAST_INCREASE li
    ON br.mtrl_num = li.mtrl_num
CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_FUTURE_MONTHS fm
CROSS JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_PARAMS p
ORDER BY br.mtrl_num, fm.forecast_month
;
