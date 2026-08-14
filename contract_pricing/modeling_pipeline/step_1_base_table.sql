-- =========================================================
-- STEP 1: CONTRACT PRICE MODELING BASE v23
-- Changes from v20:
--   - HYBRID_MODEL_KEY_3T removed; sap_cust_num_trim + mtrl_num
--     is the base grain
--   - groupby_key introduced in normalized CTE as a
--     concatenated series key across 7 dimensions:
--       sap_cust_num_trim, mtrl_num, acct_classification,
--       cust_segment, cust_prod_category, manufacturer_id,
--       subset_l2_id_resolved
--   - groupby_key used in all PARTITION BY clauses from
--     normalized onward (series_stats, avg_stats, mom_lagged)
--   - WAC_SPREAD moved from base_agg to src (computed after
--     WAC_WEIGHTED is available)
--   - MODEL_TIER removed; sap_months/l2_months informational
--
-- Mixed regime fix:
--   - New mixed_regime_flag CTE added after normalized.
--     Identifies 340B-CE/CP series where WAC-ceiling rows
--     (wac_spread=0, zombie sales) and real sub-ceiling rows
--     (wac_spread < -0.30) coexist in the same groupby_key.
--   - NORMAL_REGIME_CHANGE (87,728 series, ratio <= 100x):
--     WAC-ceiling rows excluded from training via
--     prelim_exclude_from_training=1 so the model trains on
--     the real sub-ceiling 340B price. Sub-ceiling rows are
--     kept for training and actuals as normal.
--   - EXTREME_REGIME_CHANGE (27,444 series, ratio > 100x):
--     All rows excluded from both training and actuals.
--     Near-zero sub-ceiling prices (e.g. $0.01 vs $500 WAC)
--     are anomalous and produce meaningless forecasts.
--   - regime_change_type column added to pass1_flags output
--     for downstream diagnostics and monitoring.
--
-- Bug fixes (v23 patch):
--   Fix 1 — NULL rows excluded at source in base_material_key.
--     vw_pharma_profitability_actuals_fpa contains null-financial
--     rows (NET_COS IS NULL, SLS_QTY_BEX IS NULL) that pass the
--     SLS_QTY_BEX > 0 filter because NULL > 0 evaluates to NULL
--     in SQL (not FALSE), so null rows are not excluded. These
--     null rows were the primary source of the ~62M duplicate
--     rows identified in the view (838M total vs 777M distinct).
--     They also fan out across FPA_CUST_SEG_CD values, producing
--     multiple rows per series-month in base_agg. Explicit IS NOT
--     NULL and > 0 filters added for both NET_COS and SLS_QTY_BEX.
--   Fix 5 — Negative NET_COS excluded at source in base_material_key.
--     Returns and credits produce negative NET_COS rows that
--     distort contract price calculations. Added NET_COS > 0
--     filter to exclude them before any joins or aggregation.
--     HAVING clause simplified to SUM(NET_COS) > 0 since
--     negative values can no longer reach base_agg.
--   Fix 6 — EXTREME_REGIME_CHANGE series no longer excluded
--     from training or actuals. These series are now flagged
--     only via regime_change_type = 'EXTREME_REGIME_CHANGE'
--     so that dollar reconciliation against COPA is complete.
--     Downstream consumers can filter on regime_change_type
--     to exclude from model evaluation as needed.
--   Fix 7 — mixed_regime_flag CTE moved from normalized to
--     base_layer (pre-aggregation). base_agg blends zombie
--     WAC-ceiling and vendor contract transactions into a
--     single monthly contract_price, masking extreme price
--     ratios. A series with $645 zombie price and $0.24
--     real contracted price appeared as ~2x after blending
--     instead of 2,690x at transaction level, causing
--     misclassification as NORMAL_REGIME_CHANGE instead of
--     EXTREME_REGIME_CHANGE. Fix uses CONTRACT_TYPE (available
--     pre-aggregation) instead of WAC_SPREAD/TOTAL_ZOMBIE_SALES
--     to identify transaction types, and reconstructs
--     groupby_key from base_layer dimensions using the same
--     logic as the normalized CTE for correct JOIN matching.
--   Fix 2 — CONTRACT_TYPE removed from GROUP BY ALL in base_agg.
--     A single customer+material+month can have both
--     'Vendor Contract' and 'Non-Vendor Contract' transactions
--     in COPA, which caused base_agg to produce multiple rows
--     per series-month, inflating all downstream aggregations
--     by 2-4x. CONTRACT_TYPE is now demoted to MAX().
--   Fix 3 — CUST_SEGMENT_CD removed from GROUP BY in base_agg.
--     Customers can transition between segment codes A and B
--     (both map to CP&H) within the same month, producing two
--     rows with the same groupby_key. CUST_SEGMENT_CD demoted
--     to MAX() — both A and B are CP&H so MAX('B','A')='B'
--     has no downstream impact on CUST_SEGMENT or groupby_key.
--   Fix 4 — Full defensive MAX() demotion applied to all
--     non-dimension columns in base_agg GROUP BY. SAP_CUST_NUM,
--     NDC_NUM, MTRL_NME_NVGTON, CUST_ID, CUST_ID_trim,
--     CUST_NAME, MANUFACTURER_NAME, NATIONAL_GRP_ID/DESC,
--     SUBSET_L2_DESC, COMMON_GRP_DESC, CHAIN_DESC, BRAND_NAME,
--     PRODUCT_FAMILY, THERAPEUTIC_CLASS, account_class_cd, and
--     BILL_TYPE all demoted to MAX(). GROUP BY now contains only
--     the 10 true series dimension columns. Prevents future
--     fan-out if any attribute column gains variant values.
--   - GROUP BY ALL replaced with an explicit column list.
-- Performance optimizations (v23 patch):
--   Opt 1 — All WHERE filters pushed into base_material_key.
--     POST_DT, CMPNY_CD, BUS_TYPE_CD, BILL_TYPE_CD, and
--     FPA_CUST_SEG_CD filters previously applied in base_layer
--     after the full view scan and all dimension joins. Moving
--     them to base_material_key filters the source view once
--     at the earliest point, before any joins occur, reducing
--     rows flowing through every subsequent CTE.
--   Opt 2 — Duplicate WAC column removed from base_agg.
--     WAC and WAC_WEIGHTED were computed identically. WAC
--     removed; WAC_WEIGHTED retained as the canonical column.
--   Opt 3 — dim_cust_acct_curr pre-filtered in subquery.
--     ACTIVE_CUST_IND = 'A' filter pushed into a subquery
--     so the join operates on the filtered set rather than
--     scanning the full dimension table.
--   Opt 4 — MTRL_NUM_STD carried forward as MTRL_NUM from
--     base_material_key rather than recomputed via
--     REGEXP_REPLACE in base_agg on every row.
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_modeling_base_v23 AS

WITH

base_material_key AS (
    SELECT
        t_copa.*,
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(t_copa.MTRL_NUM AS STRING), '^0+', ''), ''), '0'),
            18, '0'
        ) AS MTRL_NUM_STD
    FROM fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa t_copa
    -- All source filters applied here before any joins to minimize
    -- rows flowing through the rest of the pipeline.
    -- NULL filters added explicitly because NULL > 0 = NULL in SQL,
    -- not FALSE, so null rows pass the SLS_QTY_BEX > 0 check.
    WHERE t_copa.SLS_QTY_BEX IS NOT NULL
      AND t_copa.SLS_QTY_BEX > 0
      AND t_copa.NET_COS IS NOT NULL
      AND t_copa.NET_COS > 0            -- exclude negative net COS (returns/credits)
      AND t_copa.POST_DT BETWEEN '2022-01-01' AND '2026-05-31'
      AND t_copa.CMPNY_CD IN ('8000','8545')
      AND t_copa.BUS_TYPE_CD NOT IN ('18','19','20')
      AND t_copa.BILL_TYPE_CD IN ('ZPD1','ZPD5','ZPDS','ZPF2','ZPS1','ZPS3','ZPS6','ZPS7')
      AND t_copa.FPA_CUST_SEG_CD IN ('A','B','C','D','W','F','H')
),

material_master AS (
    SELECT
        MTRL_NUM_STD,
        MTRL_NME_NVGTON,
        THRPTC_CLSS_CDE,
        BYNG_DESC,
        NULLIF(TRIM(CAST(THRPTC_CLSS_CDE AS STRING)), '') AS THRPTC_CLSS_CDE_CLEAN
    FROM (
        SELECT
            LPAD(
                COALESCE(NULLIF(REGEXP_REPLACE(CAST(MATERIAL AS STRING), '^0+', ''), ''), '0'),
                18, '0'
            ) AS MTRL_NUM_STD,
            MTRL_NME_NVGTON,
            THRPTC_CLSS_CDE,
            BYNG_DESC,
            ROW_NUMBER() OVER (
                PARTITION BY
                    LPAD(COALESCE(NULLIF(REGEXP_REPLACE(CAST(MATERIAL AS STRING), '^0+', ''), ''), '0'), 18, '0')
                ORDER BY
                    CASE WHEN MTRL_NME_NVGTON IS NOT NULL AND TRIM(MTRL_NME_NVGTON) <> '' THEN 0 ELSE 1 END,
                    CASE WHEN THRPTC_CLSS_CDE IS NOT NULL AND TRIM(THRPTC_CLSS_CDE) <> '' THEN 0 ELSE 1 END,
                    MATERIAL
            ) AS rn
        FROM fdp_prod.psas_fdp_all_gold.vw_q_material_pharma_bw
        WHERE CURR_FLG = 'Y'
    ) x
    WHERE rn = 1
),

manufacturer AS (
    SELECT MTRL_NUM_STD, MANUFACTURER_ID, MANUFACTURER_NAME
    FROM (
        SELECT
            LPAD(
                COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
                18, '0'
            ) AS MTRL_NUM_STD,
            SPLR_ACCT_ID  AS MANUFACTURER_ID,
            SPLR_ACCT_NAM AS MANUFACTURER_NAME,
            ROW_NUMBER() OVER (
                PARTITION BY
                    LPAD(COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'), 18, '0')
                ORDER BY
                    CASE WHEN SPLR_ACCT_ID IS NOT NULL THEN 0 ELSE 1 END,
                    CASE WHEN SPLR_ACCT_NAM IS NOT NULL AND TRIM(SPLR_ACCT_NAM) <> '' THEN 0 ELSE 1 END,
                    CAST(SPLR_ACCT_ID AS STRING)
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.t_iw_em_item
        WHERE SPLR_ACCT_ID IS NOT NULL
          AND ITEM_ACTVY_CD = 'A'
    ) x
    WHERE rn = 1
),

item_curr AS (
    SELECT
        LPAD(
            COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
            18, '0'
        ) AS MTRL_NUM_STD,
        CAST(NDC_NUM AS STRING) AS NDC_NUM
    FROM (
        SELECT
            *,
            ROW_NUMBER() OVER (
                PARTITION BY EM_ITEM_NUM
                ORDER BY
                    CASE WHEN PRI_NDC_ITEM_FLG = 'Y' THEN 0 ELSE 1 END,
                    UPDATE_TS DESC
            ) AS rn
        FROM uspd_dealpricing_snowflake.edwrpt.dim_item_curr
        WHERE ITEM_ACTIVITY_CD = 'A'
    ) x
    WHERE rn = 1
),

ndc AS (
    SELECT NDC_NUM, BRND_NAM
    FROM (
        SELECT
            CAST(NDC_NUM AS STRING) AS NDC_NUM,
            BRND_NAM,
            ROW_NUMBER() OVER (
                PARTITION BY CAST(NDC_NUM AS STRING)
                ORDER BY
                    CASE WHEN BRND_NAM IS NOT NULL AND TRIM(BRND_NAM) <> '' THEN 0 ELSE 1 END,
                    BRND_NAM
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.t_ndc
    ) x
    WHERE rn = 1
),

vstx AS (
    SELECT MTRL_NUM_STD, THERAPEUTIC_CLASS, ATWRT_PROD_FAMILY
    FROM (
        SELECT
            LPAD(
                COALESCE(NULLIF(REGEXP_REPLACE(CAST(EM_ITEM_NUM AS STRING), '^0+', ''), ''), '0'),
                18, '0'
            ) AS MTRL_NUM_STD,
            THERAPEUTIC_CLASS,
            ATWRT_PROD_FAMILY,
            ROW_NUMBER() OVER (
                PARTITION BY EM_ITEM_NUM
                ORDER BY
                    CASE
                        WHEN ATWRT_PROD_FAMILY IS NOT NULL
                         AND TRIM(ATWRT_PROD_FAMILY) <> ''
                        THEN 0
                        ELSE 1
                    END
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.T_DM_VSTX_ITEM
    ) x
    WHERE rn = 1
),

ahfs AS (
    SELECT THERA_CLS_CD_CLEAN, THERA_CLS_DSCR
    FROM (
        SELECT
            NULLIF(TRIM(CAST(THERA_CLS_CD AS STRING)), '') AS THERA_CLS_CD_CLEAN,
            THERA_CLS_DSCR,
            ROW_NUMBER() OVER (
                PARTITION BY THERA_CLS_CD
                ORDER BY UPDT_DTS DESC
            ) AS rn
        FROM uspd_dealpricing_snowflake.rpt.T_AHFS_THERA_CLS
    ) x
    WHERE rn = 1
),

base_layer AS (
    SELECT
        DATE_FORMAT(t.POST_DT, 'yyyy-MM')                           AS YEAR_MONTH,
        t.MTRL_NUM_STD                                              AS MTRL_NUM,
        m.MTRL_NME_NVGTON,
        mf.MANUFACTURER_ID,
        COALESCE(NULLIF(TRIM(mf.MANUFACTURER_NAME), ''), 'UNKNOWN') AS MANUFACTURER_NAME,
        ic.NDC_NUM,
        cust_mstr.NATL_GRP_NAM                                      AS NATIONAL_GRP_DESC,
        CAST(cust_mstr.NATL_GRP_CD AS STRING)                       AS NATIONAL_GRP_ID,
        cust_mstr.COMMON_GRP_ID,
        cust_mstr.COMMON_GRP_NAME                                   AS COMMON_GRP_DESC,
        cust_mstr.ACCT_CHN_ID                                       AS CHAIN_ID,
        cust_mstr.ACCT_CHN_NAME                                     AS CHAIN_DESC,
        cust_mstr.CUST_ACCT_NAM                                     AS CUST_NAME,
        cust_mstr.ACCT_CLAS_CD                                      AS account_class_cd,
        t.FPA_CUST_SEG_CD                                           AS CUST_SEGMENT_CD,
        t.SAP_CUST_NUM,
        CAST(t.sap_cust_num AS STRING)                              AS raw_str,
        LPAD(RIGHT(CAST(t.sap_cust_num AS STRING), 6), 6, '0')     AS sap_cust_num_trim,
        cust_mstr.CUST_ACCT_ID                                      AS CUST_ID,
        LPAD(RIGHT(CAST(cust_mstr.CUST_ACCT_ID AS STRING), 6), 6, '0') AS CUST_ID_trim,

        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('A','B')     THEN 'CP&H'
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN 'SNA'
            WHEN t.FPA_CUST_SEG_CD IN ('F','H')     THEN 'MHS'
            ELSE 'INTERCO'
        END AS CUST_SEGMENT,

        CASE
            WHEN cust_mstr.ACCT_CLAS_CD = '001' THEN 'Retail'
            WHEN cust_mstr.ACCT_CLAS_CD = '002' THEN 'GPO'
            WHEN cust_mstr.ACCT_CLAS_CD = '003' THEN 'WAC'
            WHEN cust_mstr.ACCT_CLAS_CD = '004' THEN '340B-CE'
            WHEN cust_mstr.ACCT_CLAS_CD = '005' THEN '340B-CP'
            ELSE 'WAC'
        END AS ACCT_CLASSIFICATION,

        CASE
            WHEN t.SLS_CTGRY_CD IN (
                '110','111','112','114','115','116','124',
                '410','510','710','711','712','814','815','816'
            ) THEN 'Vendor Contract'
            ELSE 'Non-Vendor Contract'
        END AS CONTRACT_TYPE,

        CASE
            WHEN cust_mstr.ACCT_CLAS_CD IN ('004','005')
             AND (
                CASE
                    WHEN t.SLS_CTGRY_CD IN (
                        '110','111','112','114','115','116','124',
                        '410','510','710','711','712','814','815','816'
                    ) THEN 'Vendor Contract'
                    ELSE 'Non-Vendor Contract'
                END
             ) = 'Non-Vendor Contract'
            THEN 1
            ELSE 0
        END AS ZOMBIE_SALE_FLAG,

        'Invoice' AS BILL_TYPE,

        CASE
            WHEN t.CMPNY_CD = '8545' THEN
                CASE WHEN t.PROD_HIER_1_NUM = '85451' THEN 'MPB Plasma' ELSE 'MPB Specialty' END
            WHEN t.PROD_HIER_1_NUM IN ('00030','00050')
             AND t.SLS_CTGRY_CD NOT IN ('200','250','300','400','410','500','510') THEN 'OTC'
            WHEN t.PROD_HIER_1_NUM = '00020'
             AND t.CMPNY_CD <> '8545'                                              THEN 'GX'
            WHEN t.SLS_CTGRY_CD IN (
                '102','103','106','107','112','116',
                '122','123','701','703','711','806','807','816'
            )                                                                      THEN 'DROP SHIP'
            WHEN t.MTRL_GRP2_CD = 'W2'                        THEN 'GLP-1'
            WHEN t.MTRL_GRP2_CD IN ('R1','R2')                THEN 'BIOSIMS'
            WHEN t.MTRL_GRP2_CD IN ('V1','V2')                THEN 'VAX'
            WHEN t.MTRL_GRP2_CD IN ('S1','S3','S4','S5','S6') THEN 'APOLLO'
            ELSE 'BX'
        END AS CUST_PROD_CATEGORY,

        ndc.BRND_NAM AS BRAND_NAME,

        COALESCE(
            NULLIF(TRIM(v.ATWRT_PROD_FAMILY), ''),
            NULLIF(TRIM(ndc.BRND_NAM), ''),
            NULLIF(TRIM(v.THERAPEUTIC_CLASS), ''),
            NULLIF(TRIM(a.THERA_CLS_DSCR), ''),
            NULLIF(TRIM(m.THRPTC_CLSS_CDE), ''),
            'UNKNOWN'
        ) AS PRODUCT_FAMILY,

        COALESCE(
            NULLIF(TRIM(v.THERAPEUTIC_CLASS), ''),
            NULLIF(TRIM(a.THERA_CLS_DSCR), ''),
            NULLIF(TRIM(m.THRPTC_CLSS_CDE), ''),
            'UNKNOWN'
        ) AS THERAPEUTIC_CLASS,

        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('F','H')     THEN cust_mstr.COMMON_GRP_ID
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN cust_mstr.ACCT_CHN_ID
            ELSE cust_mstr.COMMON_GRP_ID
        END AS SUBSET_L2_ID,

        CASE
            WHEN t.FPA_CUST_SEG_CD IN ('F','H')     THEN cust_mstr.COMMON_GRP_NAME
            WHEN t.FPA_CUST_SEG_CD IN ('C','D','W') THEN cust_mstr.ACCT_CHN_NAME
            ELSE cust_mstr.COMMON_GRP_NAME
        END AS SUBSET_L2_DESC,

        t.NET_COS,
        t.UNIT_BILL_UOM,
        t.SLS_QTY_BEX,
        t.WAC,
        t.NET_REVENUE

    FROM base_material_key t
    INNER JOIN material_master m   ON t.MTRL_NUM_STD = m.MTRL_NUM_STD
    INNER JOIN manufacturer mf     ON t.MTRL_NUM_STD = mf.MTRL_NUM_STD
    INNER JOIN item_curr ic        ON t.MTRL_NUM_STD = ic.MTRL_NUM_STD
    LEFT  JOIN ndc                 ON ic.NDC_NUM = ndc.NDC_NUM
    LEFT  JOIN vstx v              ON t.MTRL_NUM_STD = v.MTRL_NUM_STD
    LEFT  JOIN ahfs a              ON m.THRPTC_CLSS_CDE_CLEAN = a.THERA_CLS_CD_CLEAN
    -- Pre-filter active customers before joining to reduce scan size
    INNER JOIN (
        SELECT
            CUST_ACCT_ID, NATL_GRP_NAM, NATL_GRP_CD, COMMON_GRP_ID,
            COMMON_GRP_NAME, ACCT_CHN_ID, ACCT_CHN_NAME, CUST_ACCT_NAM,
            ACCT_CLAS_CD
        FROM uspd_dealpricing_snowflake.edwrpt.dim_cust_acct_curr
        WHERE ACTIVE_CUST_IND = 'A'
    ) cust_mstr
        ON  LPAD(RIGHT(CAST(t.sap_cust_num AS STRING), 6), 6, '0')
          = LPAD(RIGHT(CAST(cust_mstr.CUST_ACCT_ID AS STRING), 6), 6, '0')
    -- Filters already applied in base_material_key; only residual
    -- constraints that depend on joined columns remain here
    WHERE t.SLS_QTY_BEX > 0
      AND t.SLS_QTY_BEX IS NOT NULL
),

/* =========================================================
   Base aggregation — grain is sap_cust_num_trim + mtrl_num
   + all stable series dimensions per month.

   FIX 2: CONTRACT_TYPE removed from GROUP BY and demoted to
   MAX() aggregate. A single customer+material+month can
   have both 'Vendor Contract' and 'Non-Vendor Contract'
   COPA transactions (different SLS_CTGRY_CD values), which
   caused GROUP BY ALL to produce 2-4 rows per series-month
   and inflate all downstream sums by the same factor.
   MAX() returns 'Vendor Contract' when both types coexist
   (alphabetically dominant; also semantically correct since
   the presence of any vendor contract activity is the
   meaningful signal for pricing purposes).
   ========================================================= */
/* =========================================================
   Base aggregation — grain is the 10 true series dimensions
   per month. All other columns are attributes demoted to
   MAX() to prevent fan-out when transaction-level values
   vary within a series-month (e.g. CUST_SEGMENT_CD A/B
   transition, CONTRACT_TYPE mixed vendor/non-vendor,
   name/description field variants).

   GROUP BY contains only:
     - YEAR_MONTH (time dimension)
     - MTRL_NUM, sap_cust_num_trim (core series keys)
     - CUST_SEGMENT, ACCT_CLASSIFICATION,
       CUST_PROD_CATEGORY, MANUFACTURER_ID (groupby_key dims)
     - COMMON_GRP_ID, CHAIN_ID, SUBSET_L2_ID
       (drive subset_l2_id_resolved downstream)

   Everything else is MAX() — safe because all these
   columns feed descriptive/display fields only and do not
   affect series identity or financial aggregation.
   ========================================================= */
base_agg AS (
    SELECT
        YEAR_MONTH,
        REGEXP_REPLACE(CAST(MTRL_NUM AS STRING), '^0+', '') AS MTRL_NUM,
        sap_cust_num_trim,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        MANUFACTURER_ID,
        COMMON_GRP_ID,
        CHAIN_ID,
        SUBSET_L2_ID,

        -- Transaction-level or slowly-changing attributes demoted to MAX()
        -- to prevent fan-out when values vary within a series-month.
        -- MAX() is safe here as these columns are descriptive only and
        -- do not affect series identity, groupby_key, or financial sums.
        MAX(SAP_CUST_NUM)           AS SAP_CUST_NUM,       -- raw unpadded, varies across invoice lines
        MAX(CUST_SEGMENT_CD)        AS CUST_SEGMENT_CD,    -- A/B transition months both map to CP&H
        MAX(CONTRACT_TYPE)          AS CONTRACT_TYPE,      -- vendor/non-vendor mixed months
        MAX(NDC_NUM)                AS NDC_NUM,            -- primary NDC can change if item master updated
        MAX(MTRL_NME_NVGTON)        AS MTRL_NME_NVGTON,    -- name field, minor variants possible
        MAX(CUST_ID)                AS CUST_ID,            -- raw customer ID before padding
        MAX(CUST_ID_trim)           AS CUST_ID_trim,       -- padded, defensive MAX
        MAX(CUST_NAME)              AS CUST_NAME,          -- name field, trailing space variants
        MAX(MANUFACTURER_NAME)      AS MANUFACTURER_NAME,  -- name field
        MAX(NATIONAL_GRP_ID)        AS NATIONAL_GRP_ID,    -- hierarchy attribute not in series key
        MAX(NATIONAL_GRP_DESC)      AS NATIONAL_GRP_DESC,  -- description field
        MAX(SUBSET_L2_DESC)         AS SUBSET_L2_DESC,     -- description of subset_l2_id
        MAX(COMMON_GRP_DESC)        AS COMMON_GRP_DESC,    -- description field
        MAX(CHAIN_DESC)             AS CHAIN_DESC,         -- description field
        MAX(BRAND_NAME)             AS BRAND_NAME,         -- attribute from NDC join
        MAX(PRODUCT_FAMILY)         AS PRODUCT_FAMILY,     -- derived attribute
        MAX(THERAPEUTIC_CLASS)      AS THERAPEUTIC_CLASS,  -- derived attribute
        MAX(account_class_cd)       AS account_class_cd,   -- raw code backing ACCT_CLASSIFICATION
        MAX(BILL_TYPE)              AS BILL_TYPE,          -- constant 'Invoice', defensive MAX

        -- Financial aggregates
        SUM(ZOMBIE_SALE_FLAG)                                           AS TOTAL_ZOMBIE_SALES,
        SUM(NET_COS) / NULLIF(SUM(SLS_QTY_BEX), 0)                    AS CONTRACT_PRICE,
        SUM(NET_COS)                                                    AS TOTAL_NET_COS,
        SUM(SLS_QTY_BEX)                                                AS TOTAL_SLS_QTY,
        SUM(NET_REVENUE)                                                AS TOTAL_NET_REVENUE,

        -- WAC_WEIGHTED is the canonical WAC column; duplicate WAC
        -- column removed from base_agg (was computed identically).
        -- WAC alias re-added in src CTE for downstream compatibility.
        SUM(CASE WHEN WAC IS NOT NULL AND SLS_QTY_BEX > 0 THEN WAC END)
            / NULLIF(SUM(CASE WHEN WAC IS NOT NULL AND SLS_QTY_BEX > 0 THEN SLS_QTY_BEX END), 0)
                                                                        AS WAC_WEIGHTED

    FROM base_layer
    GROUP BY
        YEAR_MONTH,
        REGEXP_REPLACE(CAST(MTRL_NUM AS STRING), '^0+', ''),
        sap_cust_num_trim,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        MANUFACTURER_ID,
        COMMON_GRP_ID,
        CHAIN_ID,
        SUBSET_L2_ID
    HAVING SUM(NET_COS) > 0  -- simplified: negative NET_COS excluded at source in base_material_key
),

/* =========================================================
   Source filter — WAC_SPREAD computed here after
   WAC_WEIGHTED is available
   ========================================================= */
src AS (
    SELECT
        *,
        -- WAC alias added here so downstream CTEs referencing WAC
        -- continue to work after the duplicate column was removed from base_agg
        WAC_WEIGHTED                                                    AS WAC,
        (TOTAL_NET_COS / NULLIF(WAC_WEIGHTED * TOTAL_SLS_QTY, 0)) - 1  AS WAC_SPREAD
    FROM base_agg
    WHERE YEAR_MONTH        IS NOT NULL
      AND MTRL_NUM          IS NOT NULL
      AND TRIM(MTRL_NUM)    <> ''
      AND CONTRACT_PRICE    IS NOT NULL
      AND TOTAL_SLS_QTY     IS NOT NULL
),

/* =========================================================
   Coverage CTEs — informational only in v23
   ========================================================= */
sap_coverage AS (
    SELECT
        MTRL_NUM,
        sap_cust_num_trim,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        COUNT(DISTINCT YEAR_MONTH) AS sap_months
    FROM src
    GROUP BY
        MTRL_NUM,
        sap_cust_num_trim,
        CUST_SEGMENT,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY
),

l2_coverage AS (
    SELECT
        MTRL_NUM,
        CUST_SEGMENT,
        CUST_SEGMENT_CD,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        COALESCE(
            CASE
                WHEN CUST_SEGMENT_CD IN ('F','H')     THEN CAST(COMMON_GRP_ID AS STRING)
                WHEN CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(CHAIN_ID AS STRING)
                ELSE CAST(COMMON_GRP_ID AS STRING)
            END,
        'NA') AS subset_l2_id_resolved,
        COUNT(DISTINCT YEAR_MONTH) AS l2_months
    FROM src
    GROUP BY
        MTRL_NUM,
        CUST_SEGMENT,
        CUST_SEGMENT_CD,
        ACCT_CLASSIFICATION,
        CUST_PROD_CATEGORY,
        COALESCE(
            CASE
                WHEN CUST_SEGMENT_CD IN ('F','H')     THEN CAST(COMMON_GRP_ID AS STRING)
                WHEN CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(CHAIN_ID AS STRING)
                ELSE CAST(COMMON_GRP_ID AS STRING)
            END,
        'NA')
),

/* =========================================================
   Normalized — groupby_key defined here using all
   7 series dimensions including subset_l2_id_resolved
   ========================================================= */
normalized AS (
    SELECT
        TO_DATE(CONCAT(s.YEAR_MONTH, '-01'))    AS cal_month_start_dt,
        s.YEAR_MONTH,
        s.CUST_SEGMENT,
        s.CUST_SEGMENT_CD,
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
        s.sap_cust_num_trim,
        s.CUST_ID,
        s.CUST_ID_trim,
        s.NDC_NUM                               AS ndc_num,
        s.WAC,
        s.WAC_WEIGHTED,
        s.WAC_SPREAD,
        s.TOTAL_NET_REVENUE,
        s.BRAND_NAME,
        s.PRODUCT_FAMILY,
        s.THERAPEUTIC_CLASS,
        s.MANUFACTURER_ID,
        s.MANUFACTURER_NAME,
        s.TOTAL_NET_COS,
        s.TOTAL_SLS_QTY,
        s.TOTAL_ZOMBIE_SALES,
        s.CONTRACT_PRICE,
        s.CONTRACT_TYPE,

        CASE
            WHEN s.PRODUCT_FAMILY    IS NOT NULL AND TRIM(s.PRODUCT_FAMILY)    NOT IN ('','UNKNOWN') THEN s.PRODUCT_FAMILY
            WHEN s.THERAPEUTIC_CLASS IS NOT NULL AND TRIM(s.THERAPEUTIC_CLASS) NOT IN ('','UNKNOWN') THEN s.THERAPEUTIC_CLASS
            WHEN s.MANUFACTURER_NAME IS NOT NULL AND TRIM(s.MANUFACTURER_NAME) NOT IN ('','UNKNOWN') THEN s.MANUFACTURER_NAME
            ELSE 'UNKNOWN'
        END AS final_product_group,

        CASE
            WHEN s.PRODUCT_FAMILY    IS NOT NULL AND TRIM(s.PRODUCT_FAMILY)    NOT IN ('','UNKNOWN') THEN 'PRODUCT_FAMILY'
            WHEN s.THERAPEUTIC_CLASS IS NOT NULL AND TRIM(s.THERAPEUTIC_CLASS) NOT IN ('','UNKNOWN') THEN 'THERAPEUTIC_CLASS'
            WHEN s.MANUFACTURER_NAME IS NOT NULL AND TRIM(s.MANUFACTURER_NAME) NOT IN ('','UNKNOWN') THEN 'MANUFACTURER_NAME'
            ELSE 'UNKNOWN'
        END AS final_product_group_level,

        COALESCE(
            CASE
                WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN CAST(s.COMMON_GRP_ID AS STRING)
                WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(s.CHAIN_ID AS STRING)
                ELSE CAST(s.COMMON_GRP_ID AS STRING)
            END,
        'NA') AS subset_l2_id_resolved,

        COALESCE(
            CASE
                WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN CAST(s.COMMON_GRP_DESC AS STRING)
                WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(s.CHAIN_DESC AS STRING)
                ELSE CAST(s.COMMON_GRP_DESC AS STRING)
            END,
        'NA') AS subset_l2_desc_resolved,

        CASE
            WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN 'COMMON_GRP_DESC'
            WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN 'CHAIN_DESC'
            ELSE 'COMMON_GRP_DESC'
        END AS subset_l2_desc_source,

        -- Informational sparsity signals
        sc.sap_months,
        lc.l2_months,

        -- Series key across all 7 dimensions
        CONCAT_WS('|',
            COALESCE(s.sap_cust_num_trim,                       'NA'),
            COALESCE(s.MTRL_NUM,                                'NA'),
            COALESCE(s.ACCT_CLASSIFICATION,                     'NA'),
            COALESCE(s.CUST_SEGMENT,                            'NA'),
            COALESCE(s.CUST_PROD_CATEGORY,                      'NA'),
            COALESCE(CAST(s.MANUFACTURER_ID AS STRING),         'NA'),
            COALESCE(
                CASE
                    WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN CAST(s.COMMON_GRP_ID AS STRING)
                    WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(s.CHAIN_ID AS STRING)
                    ELSE CAST(s.COMMON_GRP_ID AS STRING)
                END,
            'NA')
        )                                                       AS groupby_key

    FROM src s
    LEFT JOIN sap_coverage sc
        ON  s.MTRL_NUM            = sc.MTRL_NUM
        AND s.sap_cust_num_trim   = sc.sap_cust_num_trim
        AND s.CUST_SEGMENT        = sc.CUST_SEGMENT
        AND s.ACCT_CLASSIFICATION = sc.ACCT_CLASSIFICATION
        AND s.CUST_PROD_CATEGORY  = sc.CUST_PROD_CATEGORY
    LEFT JOIN l2_coverage lc
        ON  s.MTRL_NUM            = lc.MTRL_NUM
        AND s.CUST_SEGMENT        = lc.CUST_SEGMENT
        AND s.CUST_SEGMENT_CD     = lc.CUST_SEGMENT_CD
        AND s.ACCT_CLASSIFICATION = lc.ACCT_CLASSIFICATION
        AND s.CUST_PROD_CATEGORY  = lc.CUST_PROD_CATEGORY
        AND COALESCE(
                CASE
                    WHEN s.CUST_SEGMENT_CD IN ('F','H')     THEN CAST(s.COMMON_GRP_ID AS STRING)
                    WHEN s.CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(s.CHAIN_ID AS STRING)
                    ELSE CAST(s.COMMON_GRP_ID AS STRING)
                END,
            'NA') = lc.subset_l2_id_resolved
),

/* =========================================================
   Mixed regime flag — computed from base_layer BEFORE
   base_agg collapses rows. This is critical because base_agg
   blends zombie WAC-ceiling transactions with real sub-ceiling
   vendor contract rows into a single monthly contract_price,
   masking extreme price ratios. For example, a series with
   $645 zombie WAC price and $0.24 real contracted price
   appears as ~2x after blending instead of 2,690x at the
   transaction level — causing it to be misclassified as
   NORMAL_REGIME_CHANGE instead of EXTREME_REGIME_CHANGE.

   Computing from base_layer uses CONTRACT_TYPE (available
   pre-aggregation) instead of WAC_SPREAD and TOTAL_ZOMBIE_SALES
   (only available post-aggregation) to identify transaction
   types. The groupby_key is reconstructed using the same
   dimension logic as the normalized CTE so the LEFT JOIN
   in pass1_flags matches correctly.

   Two buckets:
     NORMAL_REGIME_CHANGE  — zombie/vendor ratio <= 100x.
       WAC-ceiling rows excluded from training so the model
       learns the real sub-ceiling 340B contracted price.
     EXTREME_REGIME_CHANGE — ratio > 100x. Flagged only via
       regime_change_type. Included in training and actuals
       for complete dollar reconciliation against COPA.
       Downstream consumers filter on regime_change_type
       to exclude from model evaluation as needed.
   ========================================================= */
mixed_regime_flag AS (
    SELECT
        CONCAT_WS('|',
            COALESCE(sap_cust_num_trim,                                     'NA'),
            COALESCE(REGEXP_REPLACE(CAST(MTRL_NUM AS STRING), '^0+', ''),   'NA'),
            COALESCE(ACCT_CLASSIFICATION,                                   'NA'),
            COALESCE(CUST_SEGMENT,                                          'NA'),
            COALESCE(CUST_PROD_CATEGORY,                                    'NA'),
            COALESCE(CAST(MANUFACTURER_ID AS STRING),                       'NA'),
            COALESCE(
                CASE
                    WHEN CUST_SEGMENT_CD IN ('F','H')     THEN CAST(COMMON_GRP_ID AS STRING)
                    WHEN CUST_SEGMENT_CD IN ('C','D','W') THEN CAST(CHAIN_ID AS STRING)
                    ELSE CAST(COMMON_GRP_ID AS STRING)
                END,
            'NA')
        )                                                   AS groupby_key,
        CASE
            WHEN MAX(CASE WHEN CONTRACT_TYPE = 'Non-Vendor Contract'
                         THEN NET_COS / NULLIF(SLS_QTY_BEX, 0) END)
               / NULLIF(MIN(CASE WHEN CONTRACT_TYPE = 'Vendor Contract'
                                 THEN NET_COS / NULLIF(SLS_QTY_BEX, 0) END), 0) > 100
            THEN 'EXTREME_REGIME_CHANGE'
            ELSE 'NORMAL_REGIME_CHANGE'
        END                                                 AS regime_change_type
    FROM base_layer
    WHERE ACCT_CLASSIFICATION IN ('340B-CE','340B-CP')
    GROUP BY
        sap_cust_num_trim,
        REGEXP_REPLACE(CAST(MTRL_NUM AS STRING), '^0+', ''),
        ACCT_CLASSIFICATION,
        CUST_SEGMENT,
        CUST_SEGMENT_CD,
        CUST_PROD_CATEGORY,
        MANUFACTURER_ID,
        COMMON_GRP_ID,
        CHAIN_ID,
        SUBSET_L2_ID
    HAVING
        SUM(CASE WHEN CONTRACT_TYPE = 'Non-Vendor Contract' THEN 1 ELSE 0 END) > 0
    AND SUM(CASE WHEN CONTRACT_TYPE = 'Vendor Contract'     THEN 1 ELSE 0 END) > 0
),

pass1_flags AS (
    SELECT
        n.*,
        COALESCE(mr.regime_change_type, 'NONE')         AS regime_change_type,

        -- exclude_from_actuals_flag:
        -- EXTREME_REGIME_CHANGE series are flagged via regime_change_type
        -- but NOT excluded from actuals — rows are included so dollar
        -- reconciliation against COPA is complete. Downstream consumers
        -- can filter on regime_change_type = 'EXTREME_REGIME_CHANGE' if
        -- they want to exclude these series from model evaluation.
        -- Standard zombie sale logic applies for actuals exclusion.
        CASE
            WHEN TOTAL_ZOMBIE_SALES > 0 THEN 1
            ELSE 0
        END                                             AS exclude_from_actuals_flag,

        CASE WHEN TOTAL_ZOMBIE_SALES > 0 THEN 1 ELSE 0 END AS zombie_sale_flag,

        CASE
            WHEN WAC_WEIGHTED IS NULL OR WAC_WEIGHTED < 0 THEN 1
            ELSE 0
        END AS invalid_wac_flag,

        CASE
            WHEN ACCT_CLASSIFICATION IN ('WAC','340B-CP','340B-CE') THEN 0
            WHEN WAC_WEIGHTED IS NULL OR WAC_WEIGHTED < 0           THEN 0
            WHEN CONTRACT_PRICE > WAC_WEIGHTED * 1.05               THEN 1
            ELSE 0
        END AS contract_price_above_wac_flag,

        CASE
            -- NORMAL_REGIME_CHANGE: exclude only the WAC-ceiling rows
            -- (wac_spread=0, zombie sales) from training so the model
            -- trains on the real sub-ceiling 340B price instead.
            -- EXTREME_REGIME_CHANGE: no longer excluded from training —
            -- flagged via regime_change_type for downstream use only.
            WHEN COALESCE(mr.regime_change_type, 'NONE') = 'NORMAL_REGIME_CHANGE'
             AND WAC_SPREAD = 0
             AND TOTAL_ZOMBIE_SALES > 0
            THEN 1
            WHEN ACCT_CLASSIFICATION IN ('340B-CP','340B-CE')                   THEN 0
            WHEN ACCT_CLASSIFICATION = 'WAC' AND WAC_SPREAD < -0.10             THEN 1
            WHEN ACCT_CLASSIFICATION = 'WAC'                                    THEN 0
            WHEN WAC_WEIGHTED IS NOT NULL AND WAC_WEIGHTED > 0
             AND CONTRACT_PRICE > WAC_WEIGHTED * 1.50                           THEN 1
            WHEN WAC_WEIGHTED IS NOT NULL AND WAC_WEIGHTED > 0
             AND CONTRACT_PRICE < WAC_WEIGHTED * 0.01                           THEN 1
            WHEN WAC_WEIGHTED IS NOT NULL AND WAC_WEIGHTED > 0
             AND CONTRACT_PRICE > WAC_WEIGHTED * 1.05                           THEN 1
            ELSE 0
        END AS prelim_exclude_from_training

    FROM normalized n
    LEFT JOIN mixed_regime_flag mr ON n.groupby_key = mr.groupby_key
),

/* =========================================================
   Series statistics — partitioned by groupby_key
   ========================================================= */
series_stats AS (
    SELECT
        f.*,

        PERCENTILE(
            CASE WHEN prelim_exclude_from_training = 0 THEN CONTRACT_PRICE END,
            0.5
        ) OVER (PARTITION BY groupby_key)               AS median_contract_price,

        STDDEV_SAMP(
            CASE WHEN prelim_exclude_from_training = 0 THEN CONTRACT_PRICE END
        ) OVER (PARTITION BY groupby_key)               AS stddev_contract_price,

        COUNT(
            CASE WHEN prelim_exclude_from_training = 0 THEN 1 END
        ) OVER (PARTITION BY groupby_key)               AS valid_time_series_points

    FROM pass1_flags f
),

outlier_flagged AS (
    SELECT
        s.*,

        CASE
            WHEN prelim_exclude_from_training = 1  THEN 0
            WHEN valid_time_series_points     < 3  THEN 0
            WHEN stddev_contract_price IS NULL     THEN 0
            WHEN stddev_contract_price = 0         THEN 0
            WHEN ABS(CONTRACT_PRICE - median_contract_price)
                 > 2 * stddev_contract_price       THEN 1
            ELSE 0
        END AS contract_price_outlier_flag,

        CASE
            WHEN prelim_exclude_from_training = 0
             AND (
                    valid_time_series_points < 6
                 OR stddev_contract_price IS NULL
                 OR stddev_contract_price = 0
                 OR ABS(CONTRACT_PRICE - median_contract_price)
                    <= 3 * stddev_contract_price
                 )
                THEN 1
            ELSE 0
        END AS include_in_avg_contract_price_flag

    FROM series_stats s
),

pass2_flags AS (
    SELECT
        o.*,

        CASE
            WHEN prelim_exclude_from_training = 1 THEN 1
            WHEN invalid_wac_flag             = 1 THEN 1
            WHEN contract_price_outlier_flag  = 1 THEN 1
            ELSE 0
        END AS exclude_from_training_flag

    FROM outlier_flagged o
),

/* =========================================================
   Average contract price — partitioned by groupby_key
   ========================================================= */
avg_stats AS (
    SELECT
        p.*,

        AVG(CASE WHEN include_in_avg_contract_price_flag = 1 THEN CONTRACT_PRICE END)
            OVER (PARTITION BY groupby_key)
            AS avg_contract_price_excl_outliers,

        SUM(CASE WHEN include_in_avg_contract_price_flag = 1 THEN TOTAL_NET_COS END)
            OVER (PARTITION BY groupby_key)
        / NULLIF(
            SUM(CASE WHEN include_in_avg_contract_price_flag = 1 THEN TOTAL_SLS_QTY END)
                OVER (PARTITION BY groupby_key),
          0)
            AS qty_weighted_avg_contract_price_excl_outliers,

        COUNT(CASE WHEN include_in_avg_contract_price_flag = 1 THEN 1 END)
            OVER (PARTITION BY groupby_key)
            AS months_used_in_avg_contract_price,

        COUNT(CASE WHEN contract_price_outlier_flag = 1 THEN 1 END)
            OVER (PARTITION BY groupby_key)
            AS months_excluded_as_contract_price_outliers

    FROM pass2_flags p
),

/* =========================================================
   MoM lag extraction — ordered within groupby_key
   ========================================================= */
mom_lagged AS (
    SELECT
        a.*,
        LAG(CONTRACT_PRICE) OVER (
            PARTITION BY groupby_key
            ORDER BY cal_month_start_dt
        ) AS prev_cp,
        LAG(WAC_WEIGHTED) OVER (
            PARTITION BY groupby_key
            ORDER BY cal_month_start_dt
        ) AS prev_wac,
        LAG(WAC_SPREAD) OVER (
            PARTITION BY groupby_key
            ORDER BY cal_month_start_dt
        ) AS prev_wac_spread
    FROM avg_stats a
),

mom_flags AS (
    SELECT
        m.*,
        prev_cp                                             AS prev_month_contract_price,
        prev_wac                                            AS prev_month_wac_weighted,

        (CONTRACT_PRICE - prev_cp)
            / NULLIF(prev_cp, 0)                            AS contract_price_mom_pct_change,

        MAX(CASE
            WHEN prev_cp IS NULL THEN 0
            WHEN (CONTRACT_PRICE - prev_cp) / NULLIF(prev_cp, 0) <= -0.30 THEN 1
            ELSE 0
        END) OVER (
            PARTITION BY groupby_key
            ORDER BY cal_month_start_dt
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                   AS contract_price_drop_30pct_flag,

        MAX(CASE
            WHEN prev_cp IS NULL THEN 0
            WHEN (CONTRACT_PRICE - prev_cp) / NULLIF(prev_cp, 0) >= 0.30 THEN 1
            ELSE 0
        END) OVER (
            PARTITION BY groupby_key
            ORDER BY cal_month_start_dt
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                   AS contract_price_inc_30pct_flag,

        CASE
            WHEN prev_cp IS NULL          THEN NULL
            WHEN CONTRACT_PRICE > prev_cp THEN 'INCREASE'
            WHEN CONTRACT_PRICE < prev_cp THEN 'DECREASE'
            ELSE 'FLAT'
        END                                                 AS contract_price_mom_direction,

        MAX(CASE
            WHEN prev_wac IS NULL        THEN 0
            WHEN WAC_WEIGHTED < prev_wac THEN 1
            ELSE 0
        END) OVER (
            PARTITION BY groupby_key
            ORDER BY cal_month_start_dt
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                   AS wac_mom_decrease_flag,

        (WAC_WEIGHTED - prev_wac)
            / NULLIF(prev_wac, 0)                           AS wac_mom_pct_change,

        WAC_SPREAD - prev_wac_spread                        AS wac_spread_mom_abs_change

    FROM mom_lagged m
)

SELECT
    m.*,
    MAX(CASE
        WHEN wac_mom_pct_change IS NULL  THEN 0
        WHEN wac_mom_pct_change <= -0.05 THEN 1
        ELSE 0
    END) OVER (
        PARTITION BY groupby_key
        ORDER BY cal_month_start_dt
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                       AS wac_5pct_drop_flag
FROM mom_flags m
;