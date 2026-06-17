  --Author Kathleen Jennings
  
  select
  mtrl_num,
  mtrl.MTRL_NME_NVGTON,
  cust_mstr.COMMON_GRP_ID,
  cust_mstr.COMMON_GRP_DESC,
  cust_mstr.CHAIN_ID,
  cust_mstr.CHAIN_DESC,
  cust_mstr.NATIONAL_GRP_ID,
  cust_mstr.NATIONAL_GRP_DESC,
  CASE
        WHEN t_copa.fpa_cust_seg_cd in ('A', 'B') THEN 'CP&H'
        WHEN t_copa.fpa_cust_seg_cd in ('C', 'D', 'W') THEN 'SNA'
        WHEN t_copa.fpa_cust_seg_Cd in ('F', 'H') THEN 'MHS'
        ELSE 'INTERCO'
  END AS CUST_SEGMENT,
  CASE
        WHEN cust_mstr.ACCOUNT_CLASSIFICATION_ID IN ('2') THEN 'GPO'
        WHEN cust_mstr.ACCOUNT_CLASSIFICATION_ID IN ('4') THEN '340B-CE'
        WHEN cust_mstr.ACCOUNT_CLASSIFICATION_ID IN ('5') THEN '340B-CP'
        ELSE 'WAC'
  END as acct_classification,
    CASE
    WHEN
      t_copa.cmpny_cd = '8545'
    THEN
      CASE
        WHEN t_copa.PROD_HIER_1_NUM IN ('85451') THEN 'MPB Plasma'
        ELSE 'MPB Specialty'
      END
    WHEN
      t_copa.PROD_HIER_1_NUM IN ('00030', '00050')
      AND t_copa.sls_ctgry_cd NOT IN ('200', '250', '300', '400', '410', '500', '510')
    THEN
      'OTC'
    WHEN
      t_copa.PROD_HIER_1_NUM = '00020'
      AND t_copa.cmpny_cd <> '8545'
    THEN
      'GX'
    WHEN
      t_copa.SLS_CTGRY_CD IN (
        '102',
        '103',
        '106',
        '107',
        '112',
        '116',
        '122',
        '123',
        '701',
        '703',
        '711',
        '806',
        '807',
        '816'
      )
    THEN
      'DROP SHIP'
    WHEN t_copa.MTRL_GRP2_CD = 'W2' THEN 'GLP-1'
    WHEN t_copa.MTRL_GRP2_CD IN ('R1', 'R2') THEN 'BIOSIMS'
    WHEN t_copa.MTRL_GRP2_CD IN ('V1', 'V2') THEN 'VAX'
    WHEN t_copa.MTRL_GRP2_CD IN ('S1', 'S3', 'S4', 'S5', 'S6') THEN 'APOLLO'
    ELSE 'BX'
  END AS CUST_PROD_CATEGORY,
  sum(NET_COS) / sum(SLS_QTY_BEX) as CONTRACT_PRICE
from
fdp_prod.psas_fdp_usp_gold.vw_pharma_profitability_actuals_fpa as t_copa
left join fdp_prod.psas_fdp_all_gold.vw_q_material_pharma_bw as mtrl
      on t_copa.MTRL_NUM = mtrl.MATERIAL
      and mtrl.CURR_FLG = 'Y'
left join psas_plm_dp_prod.plmdp_gold.dim_customer as cust_mstr 
on cust_mstr.ACCOUNT_ID = right(t_copa.SAP_CUST_NUM,6)
and cust_mstr.ACTIVE_FLAG = 'Y'
where post_dt between '2025-01-01' and '2025-12-31'
and CMPNY_CD in ('8000', '8545')
and BUS_TYPE_CD NOT IN ('18', '19', '20')
group by all
;