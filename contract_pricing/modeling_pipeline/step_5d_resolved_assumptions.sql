-- =========================================================
-- STEP 5D: RESOLVED ASSUMPTIONS
-- - Anchor = own latest observed contract price
-- - Trend priority:
--   1) own material if enough history
--   2) customer + product group
--   3) customer + category
--   4) segment + class-of-trade + category
--   5) else 0
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_resolved_assumptions_v2 AS
SELECT
    hp.customer_group_key_id,
    hp.mtrl_num,

    hp.cust_segment,
    hp.acct_classification,
    hp.cust_prod_category,

    hp.national_grp_id,
    hp.national_grp_desc,
    hp.subset_l2_id,
    hp.subset_l2_desc,
    hp.customer_group_key_desc,

    hp.mtrl_nme_nvgton,
    hp.ndc_num,
    hp.product_family,
    hp.therapeutic_class,
    hp.manufacturer_id,
    hp.manufacturer_name,
    hp.final_product_group,
    hp.final_product_group_level,

    hp.first_month,
    hp.last_month AS anchor_month,
    hp.months_with_history,
    hp.history_bucket,
    hp.is_short_history_flag,
    hp.has_min_12m_history_flag,
    hp.has_min_24m_history_flag,

    hp.last_contract_price AS anchor_contract_price,
    hp.last_wac_spread AS anchor_wac_spread,

    ma.expected_monthly_trend_pct AS material_monthly_trend_pct,
    pg.expected_monthly_trend_pct AS product_group_monthly_trend_pct,
    cf.expected_monthly_trend_pct AS category_monthly_trend_pct,
    sc.expected_monthly_trend_pct AS segment_category_monthly_trend_pct,

    CASE
        WHEN hp.months_with_history >= 12
         AND ma.anchor_contract_price IS NOT NULL
        THEN ma.expected_monthly_trend_pct

        WHEN pg.anchor_contract_price IS NOT NULL
        THEN pg.expected_monthly_trend_pct

        WHEN cf.anchor_contract_price IS NOT NULL
        THEN cf.expected_monthly_trend_pct

        WHEN sc.anchor_contract_price IS NOT NULL
        THEN sc.expected_monthly_trend_pct

        ELSE 0
    END AS resolved_monthly_trend_pct,

    CASE
        WHEN hp.months_with_history >= 12
         AND ma.anchor_contract_price IS NOT NULL
        THEN 'MATERIAL'

        WHEN pg.anchor_contract_price IS NOT NULL
        THEN 'CUSTOMER_PRODUCT_GROUP'

        WHEN cf.anchor_contract_price IS NOT NULL
        THEN 'CUSTOMER_CATEGORY'

        WHEN sc.anchor_contract_price IS NOT NULL
        THEN 'SEGMENT_CATEGORY'

        ELSE 'STATIC_NO_TREND'
    END AS trend_source

FROM uspd_analytics_den.analytics_gold.contract_price_history_profile_v2 hp

LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_material_assumptions_v2 ma
  ON hp.customer_group_key_id = ma.customer_group_key_id
 AND hp.mtrl_num = ma.mtrl_num

LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_fallback_product_group_v2 pg
  ON hp.customer_group_key_id = pg.customer_group_key_id
 AND hp.final_product_group = pg.final_product_group

LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_fallback_category_v2 cf
  ON hp.customer_group_key_id = cf.customer_group_key_id
 AND hp.cust_prod_category = cf.cust_prod_category

LEFT JOIN uspd_analytics_den.analytics_gold.contract_price_fallback_segment_category_v2 sc
  ON hp.cust_segment = sc.cust_segment
 AND hp.acct_classification = sc.acct_classification
 AND hp.cust_prod_category = sc.cust_prod_category
;
