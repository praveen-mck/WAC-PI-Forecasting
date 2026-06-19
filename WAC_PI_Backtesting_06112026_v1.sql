

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
   - Vaidate errors against CAGR and LRP assumptions
   ===================================================================== */


/* ---------------------------------------------------------------------
   STEP 0: Backtest runs
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUNS_v7 AS
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
   STEP 1a: NDC/Material Universe and their WAC and Sales Quantity
   - From Avinash
   --------------------------------------------------------------------- */
-- PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED_0603
select * from PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED_0603


select count(distinct COPA_MTRL_NUM) from PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED_0603
--11,019

select count(distinct MTRL_NUM) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE_v7
--10,304


/* ---------------------------------------------------------------------
   STEP 2a: Backtest universe
   - Deduplicate to one row per ndc + material
   - Keep the most frequent category if multiple exist
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE_v7 AS
WITH base AS (
    SELECT
        COPA_NDC_NUM       AS ndc_nmbr,
        COPA_MTRL_NUM      AS mtrl_num,
        CUST_PROD_CATEGORY AS cust_prod_category,
        COUNT(*) AS row_cnt
    FROM PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED_0603
    WHERE COPA_NDC_NUM IS NOT NULL
      AND COPA_MTRL_NUM IS NOT NULL
      AND LENGTH(COPA_NDC_NUM) > 0
      AND LEFT(CAST(COPA_FISCAL_YEAR_PERIOD AS VARCHAR), 4) >= '2022'
      AND MTRL_NUM IS NOT NULL
      AND TRIM(MTRL_NUM) <> ''
      AND MTRL_NUM NOT IN (
        '00000000000','00000000001','00000000002','00000000003',
        '00000000004','00000000005','00000000009','00000000010',
        '00000000069','00000000091')
      AND cust_prod_category NOT IN ('GX', 'OTC')
    GROUP BY 1,2,3
),

filter_internal_items as  
(
    SELECT 
       base.*
    FROM 
        base
    LEFT JOIN
        PRD_PSAS_DB.RPT.T_NET_CUST_SALES cs
    ON 
        TRY_TO_NUMBER(base.mtrl_num) = cs.EM_ITEM_NUM
    WHERE 
        year(cs.proc_wrk_dt)>=2022
        AND cs.CUST_BUS_TYP_CD not in ('18','19','20')  
),

ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY ndc_nmbr, mtrl_num ORDER BY row_cnt DESC, cust_prod_category) AS rn
    FROM filter_internal_items
)
SELECT
    ndc_nmbr,
    mtrl_num,
    cust_prod_category
FROM ranked
WHERE rn = 1
;


/* ---------------------------------------------------------------------
   STEP 2b: Attributes for Materials - Therapeutic class, Manufacturer Name
   - Plain join to material master
   - TRY_TO_NUMBER used only for VSTX join
   - Add ITM_CTVTY_CDE and CURR_FLG from material master
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS_v7 AS
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

/* UPDATED: VSTX with product family */
vstx AS (
    SELECT
        EM_ITEM_NUM,
        THERAPEUTIC_CLASS,
        SELL_DSCR,
        ATWRT_PROD_FAMILY
    FROM PRD_PSAS_DB.RPT.T_DM_VSTX_ITEM
    WHERE EM_ITEM_NUM IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY EM_ITEM_NUM
        ORDER BY EM_ITEM_NUM
    ) = 1
),

/* NEW: NDC table for brand fallback */
ndc AS (
    SELECT
        NDC_NUM,
        BRND_NAM
    FROM PRD_PSAS_DB.RPT.T_NDC
    WHERE NDC_NUM IS NOT NULL
    QUALIFY ROW_NUMBER() OVER ( PARTITION BY NDC_NUM ORDER BY NDC_NUM) = 1
),

/* Deduplicate AHFS */
ahfs AS (
    SELECT
        NULLIF(TRIM(TO_VARCHAR(THERA_CLS_CD)), '') AS THERA_CLS_CD_CLEAN,
        THERA_CLS_CD,
        THERA_CLS_DSCR
    FROM PRD_PSAS_DB.RPT.T_AHFS_THERA_CLS
    QUALIFY ROW_NUMBER() OVER (PARTITION BY NULLIF(TRIM(TO_VARCHAR(THERA_CLS_CD)), '') ORDER BY UPDT_DTS DESC) = 1
)

SELECT
    u.ndc_nmbr,
    u.mtrl_num,
    u.cust_prod_category,

    /* NEW: Product Family */
    CASE
        WHEN v.ATWRT_PROD_FAMILY IS NULL OR TRIM(v.ATWRT_PROD_FAMILY) = '' THEN UPPER(nd.BRND_NAM)
        ELSE UPPER(v.ATWRT_PROD_FAMILY)
    END AS product_family,
    /* Material master */
    m.THRPTC_CLSS_CDE,
    m.BYNG_DESC,
    m.ITM_CTVTY_CDE,
    m.CURR_FLG AS MTRL_CURR_FLG,

    /* VSTX */
    v.THERAPEUTIC_CLASS AS therapeutic_class,
    v.SELL_DSCR         AS sell_dscr,

    /* AHFS */
    a.THERA_CLS_DSCR,

    /* Manufacturer */
    mf.MANUFACTURER_NAME AS manufacturer_name,

    /* Coverage flags */
    CASE WHEN m.MATERIAL IS NOT NULL THEN 1 ELSE 0 END AS has_material_match,
    CASE WHEN v.EM_ITEM_NUM IS NOT NULL THEN 1 ELSE 0 END AS has_vstx_match,
    CASE WHEN mf.MANUFACTURER_NAME IS NOT NULL THEN 1 ELSE 0 END AS has_manufacturer_match,
    CASE WHEN a.THERA_CLS_DSCR IS NOT NULL THEN 1 ELSE 0 END AS has_ahfs_match,
    /* NEW: Product Family coverage flag */
    CASE WHEN v.ATWRT_PROD_FAMILY IS NOT NULL THEN 1 ELSE 0 END AS has_product_family_match,
    /* NEW: Brand coverage flag */
    CASE WHEN nd.BRND_NAM IS NOT NULL THEN 1 ELSE 0 END AS has_brand_match

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE_v7 u

LEFT JOIN mtrl m
    ON u.mtrl_num = m.MATERIAL

LEFT JOIN mfr mf
    ON m.VENDOR = mf.VENDOR_ID

LEFT JOIN vstx v
    ON TRY_TO_NUMBER(u.mtrl_num) = v.EM_ITEM_NUM

/* NEW JOIN */
LEFT JOIN ndc nd
    ON u.ndc_nmbr = nd.NDC_NUM

LEFT JOIN ahfs a
    ON m.THRPTC_CLSS_CDE_CLEAN = a.THERA_CLS_CD_CLEAN
;


/* ---------------------------------------------------------------------
   STEP 2b: Append EP Patent Expiry
   - One row per ndc + material
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS_UPD_v7 AS
WITH
EP as (
    select 
        distinct 
        upper(product) as product_family, 
        usa_patent_expiry 
    from
        PRD_ENT_PL_THIRDPARTY_DB.EVALUATE_PHARMA.V_PRODUCT_ATTRIBUTE_ODIN
    where 
        usa_patent_expiry is not null
)

select 
    attrs_v1.*,
    EP.usa_patent_expiry
from
    DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS_v7 attrs_v1
left join
    EP
ON
    attrs_v1.product_family = EP.product_family;

/* ---------------------------------------------------------------------
   STEP 2c: Deduplicate attributes
   - One row per ndc + material
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP_v7 AS
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
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS_UPD_v7 a
)
SELECT
    ndc_nmbr,
    mtrl_num,
    cust_prod_category,
    product_family,
    therapeutic_class,
    sell_dscr,
    THRPTC_CLSS_CDE,
    THERA_CLS_DSCR,
    manufacturer_name,
    BYNG_DESC,
    usa_patent_expiry,
    ITM_CTVTY_CDE,
    MTRL_CURR_FLG,
    has_material_match,
    has_vstx_match,
    has_manufacturer_match,
    has_ahfs_match
FROM ranked
WHERE rn = 1
;


select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v7 
--10,304 (after) 
--6,794 (before)


/* =====================================================================
   STEP 3: ACTUAL MONTHLY WAC & SLS QTY
   - Rebuild uniquely at ndc + mtrl + month
   - Remove category from the grain to avoid row multiplication later
   - There are some materials associated with multiple cust_prod_category; But they have the same WAC in all records
   ===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v7 AS
WITH base AS (
    SELECT
        COPA.COPA_NDC_NUM         AS ndc_nmbr,
        COPA.COPA_MTRL_NUM        AS mtrl_num,
        COPA.WAC_PRICE_COPA_DATE  AS cal_month_start_dt,
        -- COPA.BASELINE_WAC_PRICE   AS actual_wac,
        -- COPA.SNW_WAC_PRICE as actual_wac,
        coalesce(COPA.SNW_WAC_PRICE, COPA.COPA_WAC_PRICE) AS actual_wac,
        COPA.total_sls_qty_bex    AS actual_sls_qty,
        COPA.CUST_PROD_CATEGORY,
        COPA.PREFERRED_SOURCE,
        COPA.EFFECTIVE_SOURCE
    FROM 
        PRD_MT_BIG_BETS_DB.POC.WAC_PI_FORECAST_BASELINE_PRICE_V2_FINAL_MODIFIED_0603 COPA
    JOIN
        DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE_v7 mat_univ
    ON
        COPA.COPA_MTRL_NUM = mat_univ.mtrl_num 
        and COPA.COPA_NDC_NUM = mat_univ.ndc_nmbr        
),

collapsed AS (
    SELECT
        ndc_nmbr,
        mtrl_num,
        cal_month_start_dt,

        /* Keep one monthly WAC per ndc + material + month */
        MAX(actual_wac) AS actual_wac,
        SUM(actual_sls_qty) as actual_sls_qty,
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


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MTRL_HISTORY_PROFILE_v7 order by mtrl_num

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MTRL_HISTORY_PROFILE_v7 
--10304
--6794 (before)

/* =====================================================================
STEP 3B: MATERIAL LIFECYCLE
- Use all observed monthly price records from Step-3
- Defines earliest and latest observed price record for each material
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MTRL_HISTORY_PROFILE_v7 AS
SELECT
    aw.ndc_nmbr,
    aw.mtrl_num,
    MIN(aw.cal_month_start_dt) AS first_price_dt,
    MAX(aw.cal_month_start_dt) AS last_price_dt,
    MIN_BY(actual_wac, cal_month_start_dt) AS first_wac_price,
    MAX_BY(actual_wac, cal_month_start_dt) AS last_wac_price,
    COUNT(DISTINCT aw.cal_month_start_dt) AS months_with_price_records
FROM 
    DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v7 aw
GROUP BY 1,2
;


select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTIVE_PRODUCTS_v7 
--6,794

/* =====================================================================
STEP 3C: CURRENT ACTIVE FLAG
- Used only for diagnostics / coverage flag, not run eligibility
- Replace with your actual business source if needed
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTIVE_PRODUCTS_v7 AS
WITH Active_Products AS
(
    SELECT 
        MATERIAL AS mtrl_num,
        CURR_FLG,
        ITM_CTVTY_CDE
    FROM 
    (
        SELECT 
            MATERIAL,
            CURR_FLG,
            ITM_CTVTY_CDE,
            EFFECTIVE_DATE,
            ROW_NUMBER() OVER (
                PARTITION BY MATERIAL 
                ORDER BY EFFECTIVE_DATE DESC
            ) AS rn
        FROM PRD_MT_BIG_BETS_DB.POC.t_material_pharma
    )
    WHERE rn = 1
)

SELECT DISTINCT
    mat_univ.mtrl_num,
    CASE 
        WHEN CURR_FLG = 'Y' AND ITM_CTVTY_CDE = 'A' THEN 1 
        ELSE 0 
    END AS is_active_flag,
    CURR_FLG,
    ITM_CTVTY_CDE
FROM
    DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE_v7 mat_univ
LEFT JOIN
    Active_Products ap
    ON ap.mtrl_num = mat_univ.mtrl_num;



/* =====================================================================
MATERIAL LIFECYCLE TABLE (V7)
- Uses ACTUAL_WAC_MONTHLY_v7 (clean monthly WAC)
- One row per material
===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MTRL_LIFECYCLE_v7 AS

WITH base AS (
    SELECT
        mtrl_num,
        ndc_nmbr,
        cal_month_start_dt,
        actual_wac
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v7
),

/*  Keep only valid WAC records */
valid_prices AS (
    SELECT *
    FROM base
    WHERE actual_wac IS NOT NULL
      AND actual_wac > 0
),

/*  Rank to get first observed price */
ranked AS (
    SELECT
        vp.*,

        ROW_NUMBER() OVER (
            PARTITION BY mtrl_num
            ORDER BY cal_month_start_dt
        ) AS rn_first

    FROM valid_prices vp
),

/*  Aggregate lifecycle */
agg AS (
    SELECT
        vp.mtrl_num,
        MAX(vp.ndc_nmbr) AS ndc_nmbr,

        MIN(vp.cal_month_start_dt) AS first_price_dt,
        MAX(vp.cal_month_start_dt) AS last_price_dt,

        COUNT(*) AS months_with_price_records

    FROM valid_prices vp
    GROUP BY
        vp.mtrl_num
),

/*  First price */
first_price AS (
    SELECT
        mtrl_num,
        actual_wac AS first_wac_price
    FROM ranked
    WHERE rn_first = 1
)

SELECT
    a.ndc_nmbr,
    a.mtrl_num,

    a.first_price_dt,
    a.last_price_dt,
    f.first_wac_price,

    a.months_with_price_records,

    /* =====================================================
    DERIVED LIFECYCLE METRICS
    ===================================================== */

    DATEDIFF('month', a.first_price_dt, a.last_price_dt) + 1 AS lifecycle_length_months,

    CASE
        WHEN a.months_with_price_records < 6 THEN 'VERY_LOW_HISTORY'
        WHEN a.months_with_price_records < 12 THEN 'LOW_HISTORY'
        WHEN a.months_with_price_records < 24 THEN 'MEDIUM_HISTORY'
        ELSE 'HIGH_HISTORY'
    END AS history_bucket,

    CASE
        WHEN a.months_with_price_records < 12 THEN 1 ELSE 0
    END AS is_short_history_flag,

    CASE
        WHEN a.months_with_price_records >= 24 THEN 1 ELSE 0
    END AS has_sufficient_history_flag

FROM agg a
LEFT JOIN first_price f
  ON a.mtrl_num = f.mtrl_num
ORDER BY
    a.mtrl_num;




select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 order by mtrl_num

select run_id,is_eligible_for_run, count(distinct mtrl_num)
from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 
group by 1,2

select run_id,data_coverage_flag, is_eligible_for_run, count(distinct mtrl_num)
from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 
group by 1,2,3

/* =====================================================================
STEP 3D: RUN ELIGIBILITY
- Your final rule:
    eligible if first_price_dt exists and is before / on run history end
- We keep coverage flags for diagnostics, not filtering
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 AS
WITH base AS (
    SELECT
        r.run_id,
        r.jump_off_month,
        r.history_start_dt,
        r.history_end_dt,
        r.roll_1yr_start,
        r.roll_2yr_start,

        u.ndc_nmbr,
        u.mtrl_num,
        u.cust_prod_category,

        lc.first_price_dt,
        lc.last_price_dt,
        lc.months_with_price_records,

        COALESCE(ap.is_active_flag, 0) AS is_active_flag
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUNS_v7 r
    JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE_v7 u
      ON 1 = 1
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MTRL_LIFECYCLE_v7 lc
      ON u.ndc_nmbr = lc.ndc_nmbr
     AND u.mtrl_num = lc.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTIVE_PRODUCTS_v7 ap
      ON u.mtrl_num = ap.mtrl_num
),
scored AS (
    SELECT
        *,
        CASE
            WHEN first_price_dt IS NOT NULL
             AND first_price_dt <= jump_off_month
            THEN 1 ELSE 0
        END AS is_eligible_for_run,

        CASE
            WHEN first_price_dt IS NULL THEN 'NO_PRICE_HISTORY'
            WHEN first_price_dt > jump_off_month THEN 'NOT_YET_LAUNCHED_FOR_RUN'
            WHEN last_price_dt >= jump_off_month THEN 'OBSERVED_IN_WINDOW'
            WHEN is_active_flag = 1 THEN 'ACTIVE_NO_EVENT'
            ELSE 'HISTORICAL_ONLY'
        END AS data_coverage_flag
    FROM base
)
SELECT *
FROM scored
-- WHERE is_eligible_for_run = 1
;



select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7 order by run_id, mtrl_num, cal_month_start_dt

select run_id, data_coverage_flag, count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7
group by 1,2

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7 
5,786
/* =====================================================================
STEP 4: HISTORICAL OBSERVED PRICE PANEL
- Observed price records inside the run history window
- Run eligibility is already defined in STEP 3D
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7 AS
SELECT
    re.run_id,
    re.jump_off_month,
    re.history_start_dt,
    re.history_end_dt,
    re.roll_1yr_start,
    re.roll_2yr_start,

    re.ndc_nmbr,
    re.mtrl_num,
    re.cust_prod_category,
    re.first_price_dt,
    re.last_price_dt,
    re.months_with_price_records,
    re.is_active_flag,
    re.data_coverage_flag,

    aw.cal_month_start_dt,
    aw.actual_wac AS wac_price,
    aw.actual_sls_qty
    
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 re
JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v7 aw
  ON re.ndc_nmbr = aw.ndc_nmbr
 AND re.mtrl_num = aw.mtrl_num
 AND aw.cal_month_start_dt >= re.history_start_dt
 AND aw.cal_month_start_dt <= re.history_end_dt
WHERE
    is_eligible_for_run = 1
;


/* ---------------------------------------------------------------------
   STEP 5: History age
   --------------------------------------------------------------------- */
-- CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_AGE_v7 AS
-- SELECT
--     run_id,
--     mtrl_num,
--     MIN(cal_month_start_dt) AS first_dt,
--     MAX(cal_month_start_dt) AS last_dt,
--     DATEDIFF('month', MIN(cal_month_start_dt), MAX(jump_off_month)) + 1 AS months_since_first_entry
-- FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7
-- GROUP BY run_id, mtrl_num
-- ;
-- select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_AGE_v7 
-- --5,786


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_AGE_v7

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_AGE_v7
--5901

/* =====================================================================
STEP 5: HISTORY AGE
- Tenure is based on first observed price date, not only rows in window
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_AGE_v7 AS
SELECT
    re.run_id,
    re.mtrl_num,
    re.first_price_dt AS first_dt,
    MAX(h.cal_month_start_dt) AS last_dt,
    CASE
        WHEN re.first_price_dt IS NULL THEN 0
        ELSE DATEDIFF('month', re.first_price_dt, re.jump_off_month) + 1
    END AS months_since_first_entry
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 re
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7 h
  ON re.run_id = h.run_id
 AND re.mtrl_num = h.mtrl_num
WHERE
    is_eligible_for_run=1
GROUP BY
    re.run_id,
    re.mtrl_num,
    re.first_price_dt,
    re.jump_off_month
;


-- /* ---------------------------------------------------------------------
--    STEP 6: Last observed WAC
--    --------------------------------------------------------------------- */
-- CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_WAC_v7 AS
-- SELECT
--     run_id,
--     mtrl_num,
--     MAX(cal_month_start_dt) AS last_hist_month,
--     MAX_BY(wac_price, cal_month_start_dt) AS last_wac_price
-- FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7
-- GROUP BY run_id, mtrl_num
-- ;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_WAC_v7 order by run_id, mtrl_num

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_WAC_v7
--5901
/* =====================================================================
STEP 6: LAST OBSERVED WAC
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_WAC_v7 AS
SELECT
    re.run_id,
    re.mtrl_num,
    MAX(h.cal_month_start_dt) AS last_hist_month,
    MAX_BY(h.wac_price, h.cal_month_start_dt) AS last_wac_price
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 re
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7 h
  ON re.run_id = h.run_id
 AND re.mtrl_num = h.mtrl_num
WHERE
    is_eligible_for_run=1
GROUP BY
    re.run_id,
    re.mtrl_num
;



select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_WAC_v7 
--5,786

select median(price_change_pct) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
where price_change_pct>0

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 order by mtrl_num

-- /* ---------------------------------------------------------------------
--    STEP 7: Price changes
--    --------------------------------------------------------------------- */
-- CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 AS
-- SELECT
--     z.*,
--     CASE WHEN z.prev_price IS NOT NULL AND z.wac_price > z.prev_price THEN 1 ELSE 0 END AS increase_flag,
--     CASE WHEN z.prev_price > 0 THEN (z.wac_price - z.prev_price) / z.prev_price END AS price_change_pct
--     -- CASE WHEN z.prev_price > 0 AND ((z.wac_price - z.prev_price) / z.prev_price) between 0 and 0.005 THEN 1 ELSE 0 END AS low_price_change_outlier_flag,
--     -- CASE WHEN z.prev_price > 0 AND ((z.wac_price - z.prev_price) / z.prev_price) >= 5 THEN 1 ELSE 0 END AS high_price_change_outlier_flag
-- FROM (
--     SELECT
--         h.*,
--         LAG(wac_price) OVER (
--             PARTITION BY run_id, mtrl_num
--             ORDER BY cal_month_start_dt
--         ) AS prev_price
--     FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7 h
-- ) z
-- ;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 order by run_id, mtrl_num, cal_month_start_dt

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
--5786


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 order by run_id, mtrl_num, cal_month_start_dt

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 where price_change_pct < 0 order by run_id, cal_month_start_dt desc, mtrl_num

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 where price_change_pct < 0 order by run_id, cal_month_start_dt desc, mtrl_num
--308

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 where price_change_pct < 0 order by run_id desc , cal_month_start_dt desc, mtrl_num
--308

select run_id, cal_month_start_dt, count(*) 
from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 where price_change_pct < 0  
group by 1,2
order by run_id desc , cal_month_start_dt desc, mtrl_num
--308

/* =====================================================================
/* =====================================================================
STEP 7: PRICE CHANGES
- Conservative thresholds for long-term forecasting
- EXTREME defined at >= 10%
===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 AS
SELECT
    z.*,

    /* =========================================================
    BASIC FLAGS
    ========================================================= */
    CASE
        WHEN z.prev_price IS NOT NULL AND z.wac_price > z.prev_price THEN 1
        ELSE 0
    END AS increase_flag,

    CASE
        WHEN z.prev_price > 0 THEN (z.wac_price - z.prev_price) / z.prev_price
        ELSE NULL
    END AS price_change_pct,

    /* =========================================================
    LOW BASE PRICE FLAG
    ========================================================= */
    CASE
        WHEN z.prev_price < 1 THEN 1
        ELSE 0
    END AS low_base_price_flag,

    /* =========================================================
    OUTLIER FLAGS
    ========================================================= */

    -- MICRO: (0, 0.5%)
    CASE
        WHEN z.prev_price >= 1
         AND ((z.wac_price - z.prev_price) / z.prev_price) > 0
         AND ((z.wac_price - z.prev_price) / z.prev_price) < 0.005
        THEN 1 ELSE 0
    END AS low_price_change_outlier_flag,

    -- EXTREME: >= 10%
    CASE
        WHEN z.prev_price >= 1
         AND ((z.wac_price - z.prev_price) / z.prev_price) >= 0.10
        THEN 1 ELSE 0
    END AS high_price_change_outlier_flag,

    /* =========================================================
    EVENT TYPE CLASSIFICATION
    ========================================================= */
    CASE
        WHEN z.prev_price IS NULL THEN 'NO_PRIOR'

        WHEN z.wac_price <= z.prev_price THEN 'NO_INCREASE'

        -- LOW BASE
        WHEN z.prev_price < 1 THEN 'LOW_BASE'

        -- MICRO
        WHEN ((z.wac_price - z.prev_price) / z.prev_price) > 0
         AND ((z.wac_price - z.prev_price) / z.prev_price) < 0.005
        THEN 'MICRO_CHANGE'

        -- EXTREME
        WHEN ((z.wac_price - z.prev_price) / z.prev_price) >= 0.10
        THEN 'EXTREME_SPIKE'

        -- VALID SIGNAL (0.5% to 10%)
        ELSE 'VALID_INCREASE'
    END AS event_type

FROM (
    SELECT
        h.*,
        LAG(h.wac_price) OVER (
            PARTITION BY h.run_id, h.mtrl_num
            ORDER BY h.cal_month_start_dt
        ) AS prev_price
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7 h
) z
;

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 
--5,786

select low_price_change_outlier_flag, high_price_change_outlier_flag, count(distinct mtrl_num) from  DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
group by 1,2

select low_base_price_flag , count(distinct mtrl_num) from  DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
group by 1

-- /* ---------------------------------------------------------------------
--    STEP 8: Valid increase events
--    --------------------------------------------------------------------- */
-- CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_VALID_INCREASE_EVENTS_v7 AS
-- SELECT *
-- FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
-- WHERE increase_flag = 1
--   AND price_change_pct IS NOT NULL
--   AND price_change_pct >= 0.005
--   AND price_change_pct < 5
-- ;

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_VALID_INCREASE_EVENTS_v7 
--3413

/* =====================================================================
STEP 8: VALID INCREASE EVENTS
- Trusted signal layer
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_VALID_INCREASE_EVENTS_v7 AS
SELECT *
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
WHERE 
    event_type = 'VALID_INCREASE'
-- increase_flag = 1
--   AND price_change_pct IS NOT NULL
--   AND price_change_pct >= 0.005
--   AND price_change_pct < 5
;

--Different Percentiles for Price change
SELECT
    COUNT(*) AS total_events,

    -- lower tail
    APPROX_PERCENTILE(price_change_pct, 0.01) AS p01,
    APPROX_PERCENTILE(price_change_pct, 0.05) AS p05,
    APPROX_PERCENTILE(price_change_pct, 0.10) AS p10,

    -- central range
    APPROX_PERCENTILE(price_change_pct, 0.25) AS p25,
    APPROX_PERCENTILE(price_change_pct, 0.50) AS p50,  -- median
    APPROX_PERCENTILE(price_change_pct, 0.75) AS p75,

    -- upper tail
    APPROX_PERCENTILE(price_change_pct, 0.90) AS p90,
    APPROX_PERCENTILE(price_change_pct, 0.95) AS p95,
    APPROX_PERCENTILE(price_change_pct, 0.99) AS p99

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_VALID_INCREASE_EVENTS_v7;

--Before limiting extremes:
-- 95% percentile: 0.1055853481	
-- 99th percentile: 0.3949516769

--After limiting extremes:
-- 95% percentile: 0.09815844836	
-- 99th percentile: 0.0998109069


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVENT_PROFILE_v7 order by run_id, mtrl_num

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVENT_PROFILE_v7 
--5901
/* =====================================================================
STEP 8B: EVENT PROFILE
- Preserve all eligible materials
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVENT_PROFILE_v7 AS
SELECT
    re.run_id,
    re.mtrl_num,

    COUNT_IF(pc.event_type = 'VALID_INCREASE') AS valid_events,
    COUNT_IF(pc.event_type = 'MICRO_CHANGE') AS micro_events,
    COUNT_IF(pc.event_type = 'EXTREME_SPIKE') AS extreme_events,
    COUNT_IF(pc.event_type = 'NO_INCREASE') AS no_increase_events,

    AVG(CASE WHEN pc.event_type = 'VALID_INCREASE' THEN pc.price_change_pct END) AS valid_avg_pct,
    AVG(CASE WHEN pc.event_type IN ('VALID_INCREASE','MICRO_CHANGE','EXTREME_SPIKE')
             THEN pc.price_change_pct END) AS raw_avg_pct
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 re
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 pc
  ON re.run_id = pc.run_id
 AND re.mtrl_num = pc.mtrl_num
where 
    re.is_eligible_for_run = 1
GROUP BY 1,2
;


-- /* ---------------------------------------------------------------------
--    STEP 9: Last increase date
--    --------------------------------------------------------------------- */
-- CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_INCREASE_v7 AS
-- SELECT
--     run_id,
--     mtrl_num,
--     MAX(cal_month_start_dt) AS last_increase_dt
-- FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
-- GROUP BY run_id, mtrl_num
-- ;

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_INCREASE_v7 order by run_id, mtrl_num

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_INCREASE_v7
--3413
/* =====================================================================
STEP 9a: LAST VALID INCREASE DATE
- Use valid events only
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_LAST_INCREASE_v7 AS
SELECT
    run_id,
    mtrl_num,
    MAX(cal_month_start_dt) AS last_increase_dt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_VALID_INCREASE_EVENTS_v7
GROUP BY 1,2
;




-- /* ---------------------------------------------------------------------
--    STEP 10: NDC magnitude
--    --------------------------------------------------------------------- */
-- CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE_v7 AS
-- WITH full_events AS (
--     SELECT
--         run_id,
--         mtrl_num,
--         COUNT(*) AS ndc_full_events
--     FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_VALID_INCREASE_EVENTS_v7
--     GROUP BY run_id, mtrl_num
-- ),

-- events_2yr AS (
--     SELECT
--         fi.run_id,
--         fi.mtrl_num,
--         fi.price_change_pct,

--         CASE WHEN fi.cal_month_start_dt >= fi.roll_1yr_start THEN 1 ELSE 0 END AS flag_1yr,
--         CASE WHEN fi.cal_month_start_dt >= fi.roll_2yr_start
--                AND fi.cal_month_start_dt < fi.roll_1yr_start THEN 1 ELSE 0 END AS flag_prev_1yr

--     FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_VALID_INCREASE_EVENTS_v7 fi
--     WHERE fi.cal_month_start_dt >= fi.roll_2yr_start
-- ),

-- agg AS (
--     SELECT
--         run_id,
--         mtrl_num,
--         MAX(flag_1yr) AS has_event_1yr,
--         MAX(flag_prev_1yr) AS has_event_prev_1yr,
--         COUNT(*) AS total_events_2yr,
--         AVG(price_change_pct) AS avg_last_2yr_pi,
--         AVG(CASE WHEN flag_1yr = 1 THEN price_change_pct END) AS avg_1yr_pi,
--         AVG(CASE WHEN flag_prev_1yr = 1 THEN price_change_pct END) AS avg_prev_1yr_pi
--     FROM events_2yr
--     GROUP BY run_id, mtrl_num
-- )

-- SELECT
--     COALESCE(a.run_id, f.run_id) AS run_id,
--     COALESCE(a.mtrl_num, f.mtrl_num) AS mtrl_num,

--     CASE
--         WHEN has_event_1yr = 1 AND has_event_prev_1yr = 1
--             THEN 0.6 * avg_1yr_pi + 0.4 * avg_prev_1yr_pi
--         WHEN total_events_2yr >= 2
--             THEN avg_last_2yr_pi
--         WHEN total_events_2yr = 1
--             THEN 0.5 * avg_last_2yr_pi
--         ELSE 0
--     END AS ndc_exp_wac_pi_pct,

--     COALESCE(f.ndc_full_events, 0) AS ndc_full_events,
--     COALESCE(a.total_events_2yr, 0) AS ndc_roll_events

-- FROM agg a
-- FULL OUTER JOIN full_events f
--   ON a.run_id = f.run_id
--  AND a.mtrl_num = f.mtrl_num
-- ;





/* =====================================================================
STEP 10: MAGNITUDE - MODEL INPUT STATS - BASELINE SIGNAL
- Uses VALID_INCREASE events only
- Rolling 1yr / 2yr windows
- 60/40 weighting for recent behavior
- Improved fallback logic
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE_v7 AS

WITH base_materials AS (
    SELECT DISTINCT
        run_id,
        mtrl_num
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
),

valid_events AS (
    SELECT
        run_id,
        mtrl_num,
        cal_month_start_dt,
        roll_1yr_start,
        roll_2yr_start,
        price_change_pct
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
    WHERE event_type = 'VALID_INCREASE'
),

full_events AS (
    SELECT
        run_id,
        mtrl_num,
        COUNT(*) AS full_valid_events
    FROM valid_events
    GROUP BY
        run_id,
        mtrl_num
),

events_2yr AS (
    SELECT
        ve.run_id,
        ve.mtrl_num,
        ve.price_change_pct,

        CASE
            WHEN ve.cal_month_start_dt >= ve.roll_1yr_start THEN 1
            ELSE 0
        END AS flag_1yr,

        CASE
            WHEN ve.cal_month_start_dt >= ve.roll_2yr_start
             AND ve.cal_month_start_dt < ve.roll_1yr_start THEN 1
            ELSE 0
        END AS flag_prev_1yr

    FROM valid_events ve
    WHERE ve.cal_month_start_dt >= ve.roll_2yr_start
),

agg AS (
    SELECT
        run_id,
        mtrl_num,

        MAX(flag_1yr) AS has_event_1yr,
        MAX(flag_prev_1yr) AS has_event_prev_1yr,

        COUNT(*) AS total_events_2yr,

        AVG(price_change_pct) AS avg_last_2yr_pi,

        AVG(CASE
                WHEN flag_1yr = 1 THEN price_change_pct
            END) AS avg_1yr_pi,

        AVG(CASE
                WHEN flag_prev_1yr = 1 THEN price_change_pct
            END) AS avg_prev_1yr_pi

    FROM events_2yr
    GROUP BY
        run_id,
        mtrl_num
),

loe_stats AS (
    SELECT
        pc.run_id,
        pc.mtrl_num,

        MAX(loe.usa_patent_expiry) AS usa_patent_expiry,

        MAX(
            CASE
                WHEN loe.usa_patent_expiry IS NOT NULL
                 AND pc.cal_month_start_dt >= DATEADD(
                        MONTH,
                        2,   --  CRITICAL FIX (skip LOE + adjustment month)
                        DATE_TRUNC('MONTH', TO_DATE(loe.usa_patent_expiry))
                    )
                 AND pc.increase_flag = 1
                THEN 1 ELSE 0
            END
        ) AS has_post_loe_increase

    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 pc
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BF_ATTRS_UPD_v7 loe
        ON pc.mtrl_num = loe.mtrl_num
    GROUP BY
        pc.run_id,
        pc.mtrl_num
)

SELECT
    bm.run_id,
    bm.mtrl_num,

    /* =========================================================
    RECENCY-WEIGHTED / FALLBACK FORECAST SIGNAL
    ========================================================= */
    CASE
        WHEN has_event_1yr = 1 AND has_event_prev_1yr = 1
        THEN 0.6 * avg_1yr_pi + 0.4 * avg_prev_1yr_pi
    
        WHEN has_event_1yr = 1 AND has_event_prev_1yr = 0
        THEN avg_1yr_pi
    
        WHEN has_event_1yr = 0 AND has_event_prev_1yr = 1
        THEN avg_prev_1yr_pi
    
        ELSE NULL
    END AS predicted_price_change_pct,


    /* =========================================================
    DIAGNOSTIC COUNTS
    ========================================================= */
    COALESCE(fe.full_valid_events, 0) AS num_valid_events_full_history,
    COALESCE(a.total_events_2yr, 0) AS num_valid_events_2yr,
    COALESCE(a.has_event_1yr, 0) AS has_event_1yr,
    COALESCE(a.has_event_prev_1yr, 0) AS has_event_prev_1yr,

    /* =========================================================
    LOE FIELDS
    ========================================================= */
    ls.usa_patent_expiry,
    ls.has_post_loe_increase

FROM base_materials bm
LEFT JOIN agg a
    ON bm.run_id = a.run_id
   AND bm.mtrl_num = a.mtrl_num
LEFT JOIN full_events fe
    ON bm.run_id = fe.run_id
   AND bm.mtrl_num = fe.mtrl_num
LEFT JOIN loe_stats ls
    ON bm.run_id = ls.run_id
   AND bm.mtrl_num = ls.mtrl_num
;



select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING_v7 order by mtrl_num, run_id

/* ---------------------------------------------------------------------
   STEP 11: NDC timing (days between price changes)
   - Gap-based timing model
   - Filters short noise (<90 days)
   - Caps long gaps (~400 days based on P95)
   - Recency-weighted (60/40)
--------------------------------------------------------------------- */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING_v7 AS

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

    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_VALID_INCREASE_EVENTS_v7
),

/* =========================================================
REMOVE NOISY / INVALID GAPS
========================================================= */
gaps_clean AS (
    SELECT *
    FROM gaps_all
    WHERE days_since_prev IS NOT NULL
      AND days_since_prev >= 90   --  remove short-term noise
),

/* =========================================================
ROLLING 2-YEAR WINDOW + FLAGS
========================================================= */
gaps_2yr AS (
    SELECT
        run_id,
        mtrl_num,
        days_since_prev,

        CASE
            WHEN cal_month_start_dt >= roll_1yr_start THEN 1
            ELSE 0
        END AS flag_1yr,

        CASE
            WHEN cal_month_start_dt >= roll_2yr_start
             AND cal_month_start_dt < roll_1yr_start THEN 1
            ELSE 0
        END AS flag_prev_1yr

    FROM gaps_clean
    WHERE cal_month_start_dt >= roll_2yr_start
),

/* =========================================================
AGGREGATION
========================================================= */
agg AS (
    SELECT
        run_id,
        mtrl_num,

        MAX(flag_1yr) AS has_gap_1yr,
        MAX(flag_prev_1yr) AS has_gap_prev_1yr,

        COUNT(*) AS total_gaps_2yr,

        AVG(days_since_prev) AS avg_last_2yr_gap,

        AVG(CASE
                WHEN flag_1yr = 1 THEN days_since_prev
            END) AS avg_1yr_gap,

        AVG(CASE
                WHEN flag_prev_1yr = 1 THEN days_since_prev
            END) AS avg_prev_1yr_gap

    FROM gaps_2yr
    GROUP BY
        run_id,
        mtrl_num
)

/* =========================================================
FINAL TIMING LOGIC
========================================================= */
SELECT
    run_id,
    mtrl_num,

    CASE
        /* BOTH WINDOWS → best signal */
        WHEN COALESCE(has_gap_1yr, 0) = 1
         AND COALESCE(has_gap_prev_1yr, 0) = 1
        -- THEN LEAST(
        --     COALESCE(0.6 * avg_1yr_gap + 0.4 * avg_prev_1yr_gap, 365),
        --     400
        -- )      
        THEN LEAST(
            GREATEST(COALESCE(0.6 * avg_1yr_gap + 0.4 * avg_prev_1yr_gap, 365), 180),
            400
         )


        /* ONLY RECENT YEAR */
        WHEN COALESCE(has_gap_1yr, 0) = 1
         AND COALESCE(has_gap_prev_1yr, 0) = 0
        -- THEN LEAST(
        --     COALESCE(avg_1yr_gap, 365),
        --     400
        -- )        
        THEN LEAST(
            GREATEST(COALESCE(avg_1yr_gap, 365), 180),
            400
         )


        /* ONLY PREVIOUS YEAR */
        WHEN COALESCE(has_gap_1yr, 0) = 0
         AND COALESCE(has_gap_prev_1yr, 0) = 1
        THEN LEAST(
            GREATEST(COALESCE(avg_prev_1yr_gap, 365), 180),
            400
         )


        /* NO SIGNAL → default annual cadence */
        ELSE 365
    END AS ndc_exp_days_between_increases,

    /* =========================================================
    DIAGNOSTICS
    ========================================================= */
    COALESCE(total_gaps_2yr, 0) AS total_gaps_2yr

FROM agg
;




/* =====================================================================
STEP 12.: THERAPEUTIC FALLBACK
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_THERAP_FALLBACK_v7 AS
WITH material_level AS (
    SELECT
        re.run_id,
        ad.therapeutic_class,
        re.mtrl_num,
        nm.predicted_price_change_pct,
        nt.ndc_exp_days_between_increases
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 re
    JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP_v7 ad
      ON re.ndc_nmbr = ad.ndc_nmbr
     AND re.mtrl_num = ad.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE_v7 nm
      ON re.run_id = nm.run_id
     AND re.mtrl_num = nm.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING_v7 nt
      ON re.run_id = nt.run_id
     AND re.mtrl_num = nt.mtrl_num
    WHERE ad.therapeutic_class IS NOT NULL and is_eligible_for_run = 1
)
SELECT
    run_id,
    therapeutic_class,
    AVG(predicted_price_change_pct) AS therap_exp_wac_pi_pct,
    AVG(ndc_exp_days_between_increases) AS therap_exp_days_between_increases,
    COUNT(*) AS therap_material_cnt,
    COUNT(predicted_price_change_pct) AS therap_material_cnt_with_pi,
    COUNT(ndc_exp_days_between_increases) AS therap_material_cnt_with_timing
FROM material_level
GROUP BY 1,2
;


/* =====================================================================
STEP 12b.: MANUFACTURER FALLBACK
===================================================================== */
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MFR_FALLBACK_v7 AS
WITH material_level AS (
    SELECT
        re.run_id,
        ad.manufacturer_name,
        re.mtrl_num,
        nm.predicted_price_change_pct,
        nt.ndc_exp_days_between_increases
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUN_ELIGIBILITY_v7 re
    JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP_v7 ad
      ON re.ndc_nmbr = ad.ndc_nmbr
     AND re.mtrl_num = ad.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE_v7 nm
      ON re.run_id = nm.run_id
     AND re.mtrl_num = nm.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING_v7 nt
      ON re.run_id = nt.run_id
     AND re.mtrl_num = nt.mtrl_num
    WHERE ad.manufacturer_name IS NOT NULL  and is_eligible_for_run = 1
)
SELECT
    run_id,
    manufacturer_name,
    AVG(predicted_price_change_pct) AS mfr_exp_wac_pi_pct,
    AVG(ndc_exp_days_between_increases) AS mfr_exp_days_between_increases,
    COUNT(*) AS mfr_material_cnt,
    COUNT(predicted_price_change_pct) AS mfr_material_cnt_with_pi,
    COUNT(ndc_exp_days_between_increases) AS mfr_material_cnt_with_timing
FROM material_level
GROUP BY 1,2
;



select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FALLBACK_ENRICHED_v7 order by run_id, mtrl_num

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FALLBACK_ENRICHED_v7 where fallback_priority = 'NO THERAP/MFR AVAILABLE'

/* =====================================================================
STEP 12c: FALLBACK ENRICHED TABLE
- Appends therapeutic + manufacturer fallback metrics to each material
- Adds diagnostics for fallback coverage
- Establishes priority: THERAP > MFR > NONE
===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FALLBACK_ENRICHED_v7 AS

WITH base_materials AS (
    SELECT DISTINCT
        run_id,
        mtrl_num,
        ndc_nmbr
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7
)

SELECT 
    base.run_id,
    base.mtrl_num,
    base.ndc_nmbr,

    /* ================================
       ATTRIBUTES
       ================================ */
    a.therapeutic_class,
    a.manufacturer_name,

    /* ================================
       THERAPEUTIC FALLBACK
       ================================ */
    tf.therap_exp_wac_pi_pct,
    tf.therap_exp_days_between_increases,

    /* ================================
       MANUFACTURER FALLBACK
       ================================ */
    mf.mfr_exp_wac_pi_pct,
    mf.mfr_exp_days_between_increases,

    /* ================================
       DIAGNOSTIC FLAGS
       ================================ */
    CASE 
        WHEN tf.therap_exp_wac_pi_pct IS NOT NULL THEN 1 
        ELSE 0 
    END AS has_therap_fallback_magnitude,

    CASE 
        WHEN mf.mfr_exp_wac_pi_pct IS NOT NULL THEN 1 
        ELSE 0 
    END AS has_mfr_fallback_magnitude,

    /* ================================
       PRIORITY (FOR STEP‑12A USAGE)
       ================================ */
    CASE
        WHEN tf.therap_exp_wac_pi_pct IS NOT NULL THEN 'THERAP'
        WHEN mf.mfr_exp_wac_pi_pct IS NOT NULL THEN 'MFR'
        ELSE 'NO THERAP/MFR AVAILABLE'
    END AS fallback_priority,

    /* ================================
       FINAL RESOLVED FALLBACK VALUES
       - Use these directly in Step‑12A
       ================================ */

    COALESCE(
        tf.therap_exp_wac_pi_pct,
        mf.mfr_exp_wac_pi_pct
    ) AS fallback_exp_wac_pi_pct,

    COALESCE(
        tf.therap_exp_days_between_increases,
        mf.mfr_exp_days_between_increases
    ) AS fallback_exp_days_between_increases

FROM base_materials base

/* ================================
JOIN ATTRIBUTES
=============================== */
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP_v7 a
  ON base.ndc_nmbr = a.ndc_nmbr
 AND base.mtrl_num = a.mtrl_num

/* ================================
JOIN THERAPEUTIC FALLBACK
=============================== */
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_THERAP_FALLBACK_v7 tf
  ON base.run_id = tf.run_id
 AND a.therapeutic_class = tf.therapeutic_class

/* ================================
JOIN MANUFACTURER FALLBACK
=============================== */
LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_MFR_FALLBACK_v7 mf
  ON base.run_id = mf.run_id
 AND a.manufacturer_name = mf.manufacturer_name
;

-- select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7 order by run_id, mtrl_num, cal

-- select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7
-- --5786


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7 where price_change_pct < 0 order by run_id, cal_month_start_dt desc, mtrl_num


/* =====================================================================
STEP 12d: BASELINE RESOLVED ASSUMPTIONS
- Combines Step-10 magnitude + Step-11 timing
- Uses FALLBACK_ENRICHED_v7 only for NEW products (<12 months)
- Applies overrides with LOE as highest priority
- Adds stale timing override for non-new products
===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7 AS

WITH base_materials AS (
    SELECT DISTINCT
        run_id,
        mtrl_num,
        ndc_nmbr,
        jump_off_month
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7
),

/* =========================================================
LATEST HISTORICAL ROW / FLAGS
========================================================= */
latest_hist_flags AS (
    SELECT
        x.run_id,
        x.mtrl_num,
        x.cal_month_start_dt AS last_hist_month,
        x.wac_price AS last_wac_price,
        x.low_base_price_flag
    FROM (
        SELECT
            pc.*,
            ROW_NUMBER() OVER (
                PARTITION BY pc.run_id, pc.mtrl_num
                ORDER BY pc.cal_month_start_dt DESC
            ) AS rn
        FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7 pc
    ) x
    WHERE x.rn = 1
),

/* =========================================================
LAST VALID INCREASE DATE
========================================================= */
last_valid_increase AS (
    SELECT
        run_id,
        mtrl_num,
        MAX(cal_month_start_dt) AS last_increase_dt
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_PRICE_CHANGES_v7
    WHERE event_type = 'VALID_INCREASE'
    GROUP BY
        run_id,
        mtrl_num
),

/* =========================================================
HISTORY AGE
========================================================= */
hist_age AS (
    SELECT
        run_id,
        mtrl_num,
        MIN(cal_month_start_dt) AS first_dt,
        MAX(cal_month_start_dt) AS last_dt,
        DATEDIFF('month', MIN(cal_month_start_dt), MAX(jump_off_month)) + 1 AS months_since_first
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_HIST_v7
    GROUP BY
        run_id,
        mtrl_num
),

/* =========================================================
JOIN STEP-10 + STEP-11 + FALLBACK ENRICHED
========================================================= */
joined AS (
    SELECT
        bm.run_id,
        bm.mtrl_num,

        attr.cust_prod_category,
        attr.product_family,
        attr.sell_dscr,
        
        bm.jump_off_month,

        lf.last_hist_month,
        lf.last_wac_price,
        lf.low_base_price_flag,

        lvi.last_increase_dt,
        ha.months_since_first,

        ms.predicted_price_change_pct,
        ms.num_valid_events_full_history,
        ms.num_valid_events_2yr,
        ms.has_event_1yr,
        ms.has_event_prev_1yr,
        ms.usa_patent_expiry,
        ms.has_post_loe_increase,

        nt.ndc_exp_days_between_increases,
        nt.total_gaps_2yr,

        fe.ndc_nmbr,
        fe.therapeutic_class,
        fe.manufacturer_name,
        fe.has_therap_fallback_magnitude,
        fe.has_mfr_fallback_magnitude,
        fe.fallback_priority,
        fe.fallback_exp_wac_pi_pct,
        fe.fallback_exp_days_between_increases

    FROM base_materials bm
    LEFT JOIN latest_hist_flags lf
        ON bm.run_id = lf.run_id
       AND bm.mtrl_num = lf.mtrl_num
    LEFT JOIN last_valid_increase lvi
        ON bm.run_id = lvi.run_id
       AND bm.mtrl_num = lvi.mtrl_num
    LEFT JOIN hist_age ha
        ON bm.run_id = ha.run_id
       AND bm.mtrl_num = ha.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE_v7 ms
        ON bm.run_id = ms.run_id
       AND bm.mtrl_num = ms.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_TIMING_v7 nt
        ON bm.run_id = nt.run_id
       AND bm.mtrl_num = nt.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FALLBACK_ENRICHED_v7 fe
        ON bm.run_id = fe.run_id
       AND bm.mtrl_num = fe.mtrl_num
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP_v7 attr
      ON bm.ndc_nmbr = attr.ndc_nmbr
     AND bm.mtrl_num = attr.mtrl_num
),

/* =========================================================
TIMING DIAGNOSTICS
- Stale timing checked only for non-new products
- 2.0x missed cadence rule
========================================================= */
timing_diagnostics AS (
    SELECT
        j.*,

        DATEDIFF(
            'day',
            j.last_increase_dt,
            j.jump_off_month
        ) AS days_since_last_increase_asof_jumpoff,

        CASE
            WHEN j.last_increase_dt IS NOT NULL
             AND j.ndc_exp_days_between_increases IS NOT NULL
            THEN 2.0 * j.ndc_exp_days_between_increases
            ELSE NULL
        END AS stale_timing_threshold_days,

        CASE
            WHEN j.months_since_first >= 12
             AND j.predicted_price_change_pct > 0
             AND j.last_increase_dt IS NOT NULL
             AND j.ndc_exp_days_between_increases IS NOT NULL
             AND COALESCE(j.total_gaps_2yr, 0) >= 1
             AND DATEDIFF('day', j.last_increase_dt, j.jump_off_month)
                 > 2.0 * j.ndc_exp_days_between_increases
            THEN 1
            ELSE 0
        END AS stale_timing_flag

    FROM joined j
),

/* =========================================================
MAGNITUDE RESOLUTION
PRIORITY:
1. LOE FLAT
2. LOW BASE
3. NEW PRODUCT FALLBACK
4. NO SIGNAL
5. STALE TIMING
6. MODEL OUTPUT
========================================================= */
magnitude_resolved AS (
    SELECT
        td.*,

        CASE
            /* 1. LOE FLAT override (highest priority) */
            WHEN td.usa_patent_expiry IS NOT NULL
             AND TO_DATE(td.usa_patent_expiry) < td.jump_off_month
             AND COALESCE(td.has_post_loe_increase, 0) = 0
            THEN 0

            /* 2. LOW BASE PRICE override */
            WHEN COALESCE(td.low_base_price_flag, 0) = 1
            THEN 0.03

            /* 3. NEW PRODUCT -> fallback only */
            WHEN td.months_since_first < 12
            THEN COALESCE(td.fallback_exp_wac_pi_pct,
                          td.predicted_price_change_pct,
                          0)

            /* 4. NO SIGNAL */
            WHEN td.predicted_price_change_pct IS NULL
            THEN 0

            /* 5. STALE TIMING / MISSED CADENCE */
            WHEN td.stale_timing_flag = 1
            THEN 0

            /* 6. DEFAULT MODEL OUTPUT */
            ELSE td.predicted_price_change_pct
        END AS expected_wac_pi_pct,

        CASE
            WHEN td.usa_patent_expiry IS NOT NULL
             AND TO_DATE(td.usa_patent_expiry) < td.jump_off_month
             AND COALESCE(td.has_post_loe_increase, 0) = 0
            THEN 'OVERRIDE_LOE_FLAT'

            WHEN COALESCE(td.low_base_price_flag, 0) = 1
            THEN 'OVERRIDE_LOW_BASE'

            WHEN td.months_since_first < 12
             AND td.fallback_priority = 'THERAP'
            THEN 'NEW_PRODUCT_FALLBACK_THERAP'

            WHEN td.months_since_first < 12
             AND td.fallback_priority = 'MFR'
            THEN 'NEW_PRODUCT_FALLBACK_MFR'

            WHEN td.months_since_first < 12
             AND td.fallback_priority = 'NO THERAP/MFR AVAILABLE'
             AND td.predicted_price_change_pct IS NOT NULL
            THEN 'NEW_PRODUCT_MODEL_OUTPUT'

            WHEN td.months_since_first < 12
             AND td.fallback_priority = 'NO THERAP/MFR AVAILABLE'
             AND td.predicted_price_change_pct IS NULL
            THEN 'NEW_PRODUCT_NO_FALLBACK'

            WHEN td.predicted_price_change_pct IS NULL
            THEN 'OVERRIDE_NO_SIGNAL'

            WHEN td.stale_timing_flag = 1
            THEN 'OVERRIDE_STALE_TIMING'

            ELSE 'MODEL_OUTPUT'
        END AS forecast_source

    FROM timing_diagnostics td
),

/* =========================================================
TIMING RESOLUTION
- If final magnitude = 0, timing is irrelevant
- NEW products use fallback timing only
- Otherwise use NDC timing
========================================================= */
timing_resolved AS (
    SELECT
        mr.*,

        CASE
            /* If magnitude is zero -> ignore timing */
            WHEN mr.expected_wac_pi_pct <= 0
            THEN NULL

            /* NEW PRODUCT -> fallback timing only */
            WHEN mr.months_since_first < 12
            THEN COALESCE(
                    mr.fallback_exp_days_between_increases,
                    mr.ndc_exp_days_between_increases,
                    365
                 )

            /* Default for non-new if timing missing */
            WHEN mr.ndc_exp_days_between_increases IS NULL
            THEN 365

            ELSE mr.ndc_exp_days_between_increases
        END AS expected_days_between_increases,

        CASE
            WHEN mr.expected_wac_pi_pct <= 0
            THEN 'IGNORED_DUE_TO_ZERO_MAGNITUDE'

            WHEN mr.months_since_first < 12
             AND mr.fallback_priority IN ('THERAP', 'MFR')
            THEN 'NEW_PRODUCT_FALLBACK_TIMING'

            WHEN mr.months_since_first < 12
             AND mr.fallback_priority = 'NONE'
             AND mr.ndc_exp_days_between_increases IS NOT NULL
            THEN 'NEW_PRODUCT_MODEL_TIMING'

            WHEN mr.months_since_first < 12
             AND mr.fallback_priority = 'NONE'
             AND mr.ndc_exp_days_between_increases IS NULL
            THEN 'NEW_PRODUCT_DEFAULT_365'

            WHEN mr.ndc_exp_days_between_increases IS NULL
            THEN 'DEFAULT_365'

            ELSE 'MODEL_OUTPUT'
        END AS timing_source

    FROM magnitude_resolved mr
)

SELECT
    run_id,
    mtrl_num,
    ndc_nmbr,

    cust_prod_category,
    product_family,
    sell_dscr,
    
    jump_off_month,

    last_hist_month,
    last_wac_price,
    last_increase_dt,
    months_since_first,

    low_base_price_flag,

    predicted_price_change_pct,
    ndc_exp_days_between_increases,
    total_gaps_2yr,

    num_valid_events_full_history,
    num_valid_events_2yr,
    has_event_1yr,
    has_event_prev_1yr,

    usa_patent_expiry,
    has_post_loe_increase,

    therapeutic_class,
    manufacturer_name,
    has_therap_fallback_magnitude,
    has_mfr_fallback_magnitude,
    fallback_priority,
    fallback_exp_wac_pi_pct,
    fallback_exp_days_between_increases,

    days_since_last_increase_asof_jumpoff,
    stale_timing_threshold_days,
    stale_timing_flag,

    expected_wac_pi_pct,
    expected_days_between_increases,

    forecast_source,
    timing_source

FROM timing_resolved
;





select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FUTURE_ACTUAL_MONTHS_v7 order by run_id, mtrl_num, forecast_month

/* =====================================================================
STEP 13 FUTURE MONTHS (FIXED)
- Use FULL ACTUAL timeline (not HIST table)
===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FUTURE_ACTUAL_MONTHS_v7 AS

SELECT DISTINCT
    r.run_id,
    r.jump_off_month,

    aw.mtrl_num,
    aw.cal_month_start_dt AS forecast_month

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUNS_v7 r

/*  Use FULL observed timeline (this is the fix) */
JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY aw
    ON aw.cal_month_start_dt >= r.jump_off_month

/*  restrict to modeled materials */
JOIN (
    SELECT DISTINCT mtrl_num
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_NDC_MAGNITUDE_v7
) u
    ON aw.mtrl_num = u.mtrl_num
;



/* =====================================================================
   STEP 12B: FUTURE ACTUAL MONTHS
   - Use >= jump_off_month so jump-off month is included in evaluation
   ===================================================================== */

-- CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FUTURE_ACTUAL_MONTHS_v7 AS
-- SELECT DISTINCT
--     r.run_id,
--     r.jump_off_month,
--     aw.ndc_nmbr,
--     aw.mtrl_num,
--     aw.cal_month_start_dt AS forecast_month
-- FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_RUNS_v7 r
-- JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v7 aw
--   ON aw.cal_month_start_dt >= r.jump_off_month
-- JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_UNIVERSE_v7 u
--   ON aw.ndc_nmbr = u.ndc_nmbr
--  AND aw.mtrl_num = u.mtrl_num
-- ;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7  where mtrl_num = '000000000002013282' order by run_id, mtrl_num, forecast_month


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7 order by run_id, mtrl_num, forecast_month

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7
--5786

/* =====================================================================
STEP 14: FORECASTED WAC USING ORIGINAL COMPOUNDING LOGIC
- Uses resolved magnitude + timing from STEP 12A
- Keeps stepwise increase logic from historical script
===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7 AS

WITH base AS (
    SELECT
        br.run_id,
        br.mtrl_num,
        br.ndc_nmbr,
        br.cust_prod_category,
        br.product_family,
        br.sell_dscr,
        br.jump_off_month,
        br.last_hist_month,
        br.last_wac_price,
        br.last_increase_dt,
        br.expected_wac_pi_pct,
        br.expected_days_between_increases,
        br.forecast_source,
        br.timing_source,

        fm.forecast_month

    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7 br
    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FUTURE_ACTUAL_MONTHS_v7 fm
        ON br.run_id = fm.run_id
       AND br.mtrl_num = fm.mtrl_num
),

calc AS (
    SELECT
        b.*,

        DATEDIFF(
            'day',
            COALESCE(b.last_increase_dt, b.last_hist_month),
            b.forecast_month
        ) AS days_since_ref,

        CASE
            WHEN b.forecast_month IS NULL THEN NULL

            WHEN b.expected_wac_pi_pct <= 0
              OR b.expected_days_between_increases IS NULL
              OR b.expected_days_between_increases <= 0
            THEN 0

            ELSE FLOOR(
                DATEDIFF(
                    'day',
                    COALESCE(b.last_increase_dt, b.last_hist_month),
                    b.forecast_month
                ) / b.expected_days_between_increases
            )
        END AS n_expected_increases

    FROM base b
)

SELECT
    run_id,
    mtrl_num,
    ndc_nmbr,
    cust_prod_category,
    product_family,
    sell_dscr,
    jump_off_month,
    last_hist_month,
    last_wac_price,
    last_increase_dt,

    expected_wac_pi_pct,
    expected_days_between_increases,

    forecast_source,
    timing_source,

    forecast_month,
    days_since_ref,
    n_expected_increases,

    CASE
        WHEN forecast_month IS NULL THEN NULL
        WHEN last_wac_price IS NULL THEN NULL
        ELSE last_wac_price * POWER(1 + expected_wac_pi_pct, n_expected_increases)
    END AS forecasted_wac

FROM calc
;


--QC for 14
--1
-- MODEL driven vs. OVerrides
SELECT
    run_id,
    forecast_source,
    COUNT(DISTINCT mtrl_num) AS material_cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7
GROUP BY
    run_id,
    forecast_source
ORDER BY
    run_id,
    material_cnt DESC;

--2
-- Post LOE increases 
SELECT
    run_id,
    COUNT(DISTINCT mtrl_num) AS total_materials,

    COUNT(DISTINCT CASE
        WHEN forecast_source = 'OVERRIDE_LOE_FLAT'
        THEN mtrl_num
    END) AS loe_flat_materials,

    COUNT(DISTINCT CASE
        WHEN usa_patent_expiry IS NOT NULL
        THEN mtrl_num
    END) AS materials_with_loe

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7
GROUP BY
    run_id
ORDER BY
    run_id;

--3
-- Model driven Timing vs. Timing overrides 
SELECT
    run_id,
    timing_source,
    COUNT(DISTINCT mtrl_num) AS material_cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7
GROUP BY
    run_id,
    timing_source
ORDER BY
    run_id,
    material_cnt DESC;

--4
--Timing percentiles
SELECT
    run_id,

    APPROX_PERCENTILE(expected_days_between_increases, 0.50) AS p50_days,
    APPROX_PERCENTILE(expected_days_between_increases, 0.75) AS p75_days,
    APPROX_PERCENTILE(expected_days_between_increases, 0.90) AS p90_days,
    APPROX_PERCENTILE(expected_days_between_increases, 0.95) AS p95_days,

    COUNT(*) AS total_rows

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7
WHERE expected_days_between_increases IS NOT NULL
GROUP BY
    run_id;

--5
SELECT
    run_id,
    n_expected_increases,
    COUNT(*) AS row_cnt
FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7
GROUP BY
    run_id,
    n_expected_increases
ORDER BY
    run_id,
    n_expected_increases;

--6

SELECT
    run_id,

    AVG(n_expected_increases) AS avg_increases,
    MAX(n_expected_increases) AS max_increases,

    COUNT(DISTINCT mtrl_num) AS materials

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7
GROUP BY
    run_id;


--7
SELECT
    run_id,
    mtrl_num,
    forecast_month,
    last_wac_price,
    forecasted_wac,

    expected_wac_pi_pct,
    n_expected_increases,

    forecasted_wac / NULLIF(last_wac_price, 0) AS growth_factor

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7
WHERE forecasted_wac IS NOT NULL
  AND forecasted_wac > 1.5 * last_wac_price   -- threshold
ORDER BY
    growth_factor DESC
LIMIT 50;


--8
SELECT
    run_id,

    APPROX_PERCENTILE(forecasted_wac / NULLIF(last_wac_price, 0), 0.50) AS p50_growth,
    APPROX_PERCENTILE(forecasted_wac / NULLIF(last_wac_price, 0), 0.90) AS p90_growth,
    APPROX_PERCENTILE(forecasted_wac / NULLIF(last_wac_price, 0), 0.95) AS p95_growth,
    MAX(forecasted_wac / NULLIF(last_wac_price, 0)) AS max_growth

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7
GROUP BY
    run_id;


--9
SELECT
    run_id,
    COUNT(DISTINCT CASE
        WHEN n_expected_increases = 0 THEN mtrl_num
    END) AS no_increase_materials,

    COUNT(DISTINCT mtrl_num) AS total_materials,

    (COUNT(DISTINCT CASE
        WHEN n_expected_increases = 0 THEN mtrl_num
    END)) / COUNT(DISTINCT mtrl_num) AS ratio

FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7
GROUP BY
    run_id;


select pass_flag_vs_actual_error_threshold, count(*) 
from
DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_DETAIL_v7 
group by 
1

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_DETAIL_v7 order by run_id, mtrl_num, forecast_month


/* =====================================================================
STEP 15: FORECAST EVALUATION DETAIL TABLE (POWER BI READY)
- One row per run_id + mtrl_num + forecast_month
- Attaches forecast outputs + actuals + evaluation metrics
- Designed to align with BRD evaluation/detail-table requirements
===================================================================== */

CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_DETAIL_v7 AS

WITH forecast_base AS (
    SELECT
        f.run_id,
        f.mtrl_num,

        f.cust_prod_category,
        f.product_family,
        f.sell_dscr,
        
        f.forecast_month,

        f.jump_off_month,
        f.ndc_nmbr,

        f.last_hist_month,
        f.last_wac_price,
        f.last_increase_dt,

        f.expected_wac_pi_pct,
        f.expected_days_between_increases,
        f.forecast_source,
        f.timing_source,

        f.days_since_ref,
        f.n_expected_increases,
        f.forecasted_wac
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_FORECASTED_v7 f
),

attrs AS (
    SELECT DISTINCT
        ndc_nmbr,
        mtrl_num,
        therapeutic_class,
        manufacturer_name
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ATTRS_DEDUP_v7
),

joined AS (
    SELECT
        fb.*,

        br.months_since_first,
        br.low_base_price_flag,
        br.predicted_price_change_pct,
        br.ndc_exp_days_between_increases,
        br.total_gaps_2yr,
        br.num_valid_events_full_history,
        br.num_valid_events_2yr,
        br.has_event_1yr,
        br.has_event_prev_1yr,
        br.usa_patent_expiry,
        br.has_post_loe_increase,
        br.has_therap_fallback_magnitude,
        br.has_mfr_fallback_magnitude,
        br.fallback_priority,
        br.fallback_exp_wac_pi_pct,
        br.fallback_exp_days_between_increases,
        br.days_since_last_increase_asof_jumpoff,
        br.stale_timing_threshold_days,
        br.stale_timing_flag,

        a.therapeutic_class,
        a.manufacturer_name,

        aw.actual_wac,
        aw.actual_sls_qty

    FROM forecast_base fb

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_BASELINE_RESOLVED_v7 br
      ON fb.run_id = br.run_id
     AND fb.mtrl_num = br.mtrl_num

    LEFT JOIN attrs a
      ON fb.ndc_nmbr = a.ndc_nmbr
     AND fb.mtrl_num = a.mtrl_num

    LEFT JOIN DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v7 aw
      ON fb.mtrl_num = aw.mtrl_num
     AND fb.forecast_month = aw.cal_month_start_dt
),

calc_1 AS (
    SELECT
        j.*,

        /* =========================================================
        BASE OUTPUTS
        ========================================================= */
        j.forecasted_wac * j.actual_sls_qty AS forecasted_dollars,
        j.actual_wac * j.actual_sls_qty     AS actual_dollars,

        /* =========================================================
        NEW FORECAST ERROR METRICS (VS ACTUAL)
        ========================================================= */
        (j.forecasted_wac - j.actual_wac) AS error_new_wac,
        ABS(j.forecasted_wac - j.actual_wac) AS ae_new_wac,

        CASE
            WHEN j.actual_wac IS NOT NULL AND j.actual_wac <> 0
            THEN (j.forecasted_wac - j.actual_wac) / j.actual_wac
            ELSE NULL
        END AS bias_new_wac,

        CASE
            WHEN j.actual_wac IS NOT NULL AND j.actual_wac <> 0
            THEN ABS(j.forecasted_wac - j.actual_wac) / ABS(j.actual_wac)
            ELSE NULL
        END AS ape_new_wac,

        ((j.forecasted_wac * j.actual_sls_qty) - (j.actual_wac * j.actual_sls_qty)) AS error_new_dollars,
        ABS((j.forecasted_wac * j.actual_sls_qty) - (j.actual_wac * j.actual_sls_qty)) AS ae_new_dollars,

        CASE
            WHEN (j.actual_wac * j.actual_sls_qty) IS NOT NULL
             AND (j.actual_wac * j.actual_sls_qty) <> 0
            THEN ((j.forecasted_wac * j.actual_sls_qty) - (j.actual_wac * j.actual_sls_qty))
                 / (j.actual_wac * j.actual_sls_qty)
            ELSE NULL
        END AS bias_new_dollars,

        CASE
            WHEN (j.actual_wac * j.actual_sls_qty) IS NOT NULL
             AND (j.actual_wac * j.actual_sls_qty) <> 0
            THEN ABS((j.forecasted_wac * j.actual_sls_qty) - (j.actual_wac * j.actual_sls_qty))
                 / ABS(j.actual_wac * j.actual_sls_qty)
            ELSE NULL
        END AS ape_new_dollars,

        /* =========================================================
        BENCHMARK PLACEHOLDERS
        - populate later when old forecast / CAGR / LRP are available
        ========================================================= */
        CAST(NULL AS FLOAT) AS forecast_old_wac,
        CAST(NULL AS FLOAT) AS forecast_old_dollars,
        CAST(NULL AS FLOAT) AS cagr_2yr_wac,
        CAST(NULL AS FLOAT) AS cagr_4yr_wac,
        CAST(NULL AS FLOAT) AS lrp_wac

    FROM joined j
),

calc_2 AS (
    SELECT
        c1.*,

        /* =========================================================
        OLD FORECAST PLACEHOLDER METRICS
        ========================================================= */
        CAST(NULL AS FLOAT) AS error_old_wac,
        CAST(NULL AS FLOAT) AS ae_old_wac,
        CAST(NULL AS FLOAT) AS ape_old_wac,

        CAST(NULL AS FLOAT) AS error_old_dollars,
        CAST(NULL AS FLOAT) AS ae_old_dollars,
        CAST(NULL AS FLOAT) AS ape_old_dollars,

        /* =========================================================
        DELTA / FVA PLACEHOLDERS
        ========================================================= */
        CAST(NULL AS FLOAT) AS delta_error_wac,
        CAST(NULL AS FLOAT) AS delta_error_dollars,
        CAST(NULL AS FLOAT) AS delta_mape_wac,
        CAST(NULL AS FLOAT) AS delta_mape_dollars,
        CAST(NULL AS FLOAT) AS fva_wac,
        CAST(NULL AS FLOAT) AS fva_dollars

    FROM calc_1 c1
),

weighted AS (
    SELECT
        c2.*,

        /* =========================================================
        WEIGHTED PERCENT ERROR
        - BRD asks for weighted percent error using dollar impact
        - use row abs dollar error divided by total abs dollar error in run
        ========================================================= */
        CASE
            WHEN SUM(ABS(c2.error_new_dollars)) OVER (PARTITION BY c2.run_id) <> 0
            THEN ABS(c2.error_new_dollars)
                 / SUM(ABS(c2.error_new_dollars)) OVER (PARTITION BY c2.run_id)
            ELSE NULL
        END AS weighted_percent_error,

        /* =========================================================
        REVENUE SHARE (useful for materiality bands in reporting)
        ========================================================= */
        CASE
            WHEN SUM(ABS(c2.actual_dollars)) OVER (PARTITION BY c2.run_id) <> 0
            THEN ABS(c2.actual_dollars)
                 / SUM(ABS(c2.actual_dollars)) OVER (PARTITION BY c2.run_id)
            ELSE NULL
        END AS revenue_share

    FROM calc_2 c2
),

ranked AS (
    SELECT
        w.*,

        /* =========================================================
        MATERIALITY BUCKETS
        - BRD references top 20 / middle 60 / bottom 20 by sales
        - Implement using NTILE over actual dollars within each run_id
        ========================================================= */
        NTILE(5) OVER (
            PARTITION BY w.run_id
            ORDER BY ABS(w.actual_dollars) DESC NULLS LAST
        ) AS revenue_quintile_desc

    FROM weighted w
),

final_calc AS (
    SELECT
        r.*,

        /* =========================================================
        MATERIALITY BAND
        ========================================================= */
        CASE
            WHEN r.revenue_quintile_desc = 1 THEN 'TOP_20'
            WHEN r.revenue_quintile_desc IN (2,3,4) THEN 'MIDDLE_60'
            WHEN r.revenue_quintile_desc = 5 THEN 'BOTTOM_20'
            ELSE 'UNKNOWN'
        END AS materiality_band,

        /* =========================================================
        MATERIALITY ERROR THRESHOLD (BRD)
        - Top 20% within 3%
        - Middle 60% within 10%
        - Bottom 20% within 20%
        ========================================================= */
        CASE
            WHEN r.revenue_quintile_desc = 1 THEN 0.03
            WHEN r.revenue_quintile_desc IN (2,3,4) THEN 0.10
            WHEN r.revenue_quintile_desc = 5 THEN 0.20
            ELSE NULL
        END AS materiality_threshold_pct,

        /* =========================================================
        PASS / FAIL VS ACTUALS
        - BRD mentions error threshold e.g. MAPE < 20%
        ========================================================= */
        CASE
            WHEN r.ape_new_wac IS NOT NULL AND r.ape_new_wac < 0.20 THEN 1
            WHEN r.ape_new_wac IS NOT NULL THEN 0
            ELSE NULL
        END AS pass_flag_vs_actual_error_threshold,

        CASE
            WHEN r.ape_new_dollars IS NOT NULL
             AND (
                    (r.revenue_quintile_desc = 1 AND r.ape_new_dollars <= 0.03) OR
                    (r.revenue_quintile_desc IN (2,3,4) AND r.ape_new_dollars <= 0.10) OR
                    (r.revenue_quintile_desc = 5 AND r.ape_new_dollars <= 0.20)
                 )
            THEN 1
            WHEN r.ape_new_dollars IS NOT NULL THEN 0
            ELSE NULL
        END AS pass_flag_vs_materiality_threshold,

        /* =========================================================
        PLACEHOLDER PASS/FAIL FLAGS
        ========================================================= */
        CAST(NULL AS INTEGER) AS pass_flag_vs_old_forecast,
        CAST(NULL AS INTEGER) AS pass_flag_vs_cagr,

        /* =========================================================
        EXCEPTION / REVIEW CLASSIFICATION
        ========================================================= */
        CASE
            WHEN r.ape_new_dollars IS NOT NULL
             AND (
                    (r.revenue_quintile_desc = 1 AND r.ape_new_dollars > 0.03) OR
                    (r.revenue_quintile_desc IN (2,3,4) AND r.ape_new_dollars > 0.10) OR
                    (r.revenue_quintile_desc = 5 AND r.ape_new_dollars > 0.20)
                 )
             AND ABS(r.actual_dollars) IS NOT NULL
             AND ABS(r.actual_dollars) > 0
            THEN 'CRITICAL'
            WHEN r.ape_new_wac IS NOT NULL AND r.ape_new_wac > 0.20
            THEN 'MODERATE'
            ELSE 'PASS'
        END AS review_priority,

        /* =========================================================
        ROOT CAUSE SEEDING
        - initial diagnostic tags for Power BI filtering
        ========================================================= */
        CASE
            WHEN r.forecast_source = 'OVERRIDE_LOE_FLAT' THEN 'STRUCTURAL_CHANGE_LOE'
            WHEN r.forecast_source = 'OVERRIDE_LOW_BASE' THEN 'LOW_BASE_PRICE_OVERRIDE'
            WHEN r.forecast_source = 'OVERRIDE_NO_SIGNAL' THEN 'NO_MEANINGFUL_INCREASE_SIGNAL'
            WHEN r.forecast_source = 'OVERRIDE_STALE_TIMING' THEN 'STALE_TIMING_CADENCE_BROKEN'
            WHEN r.forecast_source LIKE 'NEW_PRODUCT_FALLBACK%' THEN 'NEW_PRODUCT_FALLBACK'
            WHEN r.forecast_source = 'MODEL_OUTPUT' THEN 'MODEL_OUTPUT'
            ELSE 'OTHER'
        END AS root_cause_seed,

        /* =========================================================
        OPTIONAL EXPLOSION FLAG
        ========================================================= */
        CASE
            WHEN r.last_wac_price IS NOT NULL
             AND r.last_wac_price > 0
             AND r.forecasted_wac > 5 * r.last_wac_price
            THEN 1 ELSE 0
        END AS forecast_explosion_flag

    FROM ranked r
)

SELECT
    /* =========================================================
    DETAIL TABLE FIELDS FOR POWER BI
    ========================================================= */
    run_id,
    mtrl_num,
    ndc_nmbr,

    cust_prod_category,
    product_family,
    sell_dscr,
        

    therapeutic_class,
    manufacturer_name,
    forecast_month,

    jump_off_month,
    last_hist_month,
    last_increase_dt,
    months_since_first,

    forecasted_wac AS forecast_new,
    -- forecast_old_wac AS forecast_old,
    actual_wac,

    expected_wac_pi_pct,
    expected_days_between_increases,
    forecast_source,
    timing_source,

    days_since_ref,
    n_expected_increases,

    actual_sls_qty,
    forecasted_dollars,
    actual_dollars,

    /* =========================================================
    CORE ERROR METRICS
    ========================================================= */
    error_new_wac,
    ae_new_wac,
    bias_new_wac,
    ape_new_wac,

    error_new_dollars,
    ae_new_dollars,
    bias_new_dollars,
    ape_new_dollars,

    -- error_old_wac,
    -- ae_old_wac,
    -- ape_old_wac,

    -- error_old_dollars,
    -- ae_old_dollars,
    -- ape_old_dollars,

    -- delta_error_wac,
    -- delta_error_dollars,
    -- delta_mape_wac,
    -- delta_mape_dollars,
    -- fva_wac,
    -- fva_dollars,

    weighted_percent_error,
    revenue_share,

    materiality_band,
    materiality_threshold_pct,

    pass_flag_vs_actual_error_threshold,
    pass_flag_vs_materiality_threshold,
    -- pass_flag_vs_old_forecast,
    -- pass_flag_vs_cagr,

    review_priority,
    root_cause_seed,

    /* =========================================================
    DIAGNOSTIC / MODEL CONTEXT
    ========================================================= */
    low_base_price_flag,
    predicted_price_change_pct,
    ndc_exp_days_between_increases,
    total_gaps_2yr,
    num_valid_events_full_history,
    num_valid_events_2yr,
    has_event_1yr,
    has_event_prev_1yr,

    usa_patent_expiry,
    has_post_loe_increase,
    has_therap_fallback_magnitude,
    has_mfr_fallback_magnitude,
    fallback_priority,
    fallback_exp_wac_pi_pct,
    fallback_exp_days_between_increases,

    days_since_last_increase_asof_jumpoff,
    stale_timing_threshold_days,
    stale_timing_flag,

    forecast_explosion_flag,

    /* =========================================================
    BENCHMARK PLACEHOLDERS
    ========================================================= */
    -- cagr_2yr_wac,
    -- cagr_4yr_wac,
    -- lrp_wac

FROM final_calc
where forecast_month is not null
;


select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_DETAIL_v7

select count(distinct mtrl_num) from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_DETAIL_v7

select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_DETAIL_v7 where forecast_new is null



select * from DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_SUMMARY_RUN_v7 

select run_id, row_cnt,material_cnt, wac_wape_new, dollar_wape_new, mape_new_wac, mape_new_dollars
from
DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_SUMMARY_RUN_v7 



---------------------------------------------------------------------------------------
-- FINAL TABLE: EVAL v8 WITH DECREASE FLAGS (FULL BUILD)
----------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_v8_WITH_DECREASE_FLAG AS

/* =========================================================
STEP 1: BASE ACTUALS (clean monthly WAC)
========================================================= */

WITH base_actuals AS (
    SELECT
        ndc_nmbr,
        mtrl_num,
        cal_month_start_dt,
        actual_wac
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_ACTUAL_WAC_MONTHLY_v7
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
STEP 4: BASE FORECAST/EVAL TABLE (v7)
========================================================= */

eval_base AS (
    SELECT *
    FROM DEV_MT_BIG_BETS_DB.POC.WAC_PI_BT_EVAL_DETAIL_v7
),

/* =========================================================
STEP 5: FINAL JOIN
========================================================= */

final AS (
    SELECT
        e.*,

        /* ✅ CORE FLAGS (what you asked for) */
        COALESCE(d.has_decrease_flag, 0) AS has_decrease_flag,
        COALESCE(d.has_significant_decrease_flag, 0) AS has_significant_decrease_flag,

        /* ✅ OPTIONAL DIAGNOSTICS */
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
