--Author: Avinash 

USE ROLE SBX_EA_GENERAL_FR;
USE WAREHOUSE SBX_EA_GENERAL_FR_WH;
USE DATABASE PRD_MT_BIG_BETS_DB;
 
  select
  mtrl_num,
  mtrl.MTRL_NME_NVGTON,
  cust_mstr.COMMON_GRP_ID,
  cust_mstr.common_grp_name as COMMON_GRP_DESC,
  cust_mstr.cust_chn_id as CHAIN_ID,
  cust_mstr.cust_chn_name as CHAIN_DESC,
  cust_mstr.natl_grp_cd as NATIONAL_GRP_ID,
  cust_mstr.natl_grp_nam as NATIONAL_GRP_DESC,
  CASE
        WHEN t_copa.fpa_cust_seg_cd in ('A', 'B') THEN 'CP&H'
        WHEN t_copa.fpa_cust_seg_cd in ('C', 'D', 'W') THEN 'SNA'
        WHEN t_copa.fpa_cust_seg_Cd in ('F', 'H') THEN 'MHS'
        ELSE 'INTERCO'
  END AS CUST_SEGMENT,
 CASE
      WHEN cust_mstr.acct_clas_cd IN ('2') THEN 'GPO'
      WHEN cust_mstr.acct_clas_cd IN ('4') THEN '340B-CE'
        WHEN cust_mstr.acct_clas_cd IN ('5') THEN '340B-CP'
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
PRD_MT_BIG_BETS_DB.POC.t_pharma_profitability_actuals_fpa_0525 as t_copa
 LEFT JOIN (SELECT * FROM PRD_MT_BIG_BETS_DB.POC.t_material_pharma
                    WHERE CURR_FLG = 'Y') MTRL
        ON t_copa.MTRL_NUM = mtrl.MATERIAL
left join prd_psas_db.edwrpt.dim_cust_acct_curr cust_mstr
     ON cust_mstr.CUST_ACCT_ID = right(t_copa.SAP_CUST_NUM,6)
--and cust_mstr.ACTIVE_CUST_IND = 'Y'
where post_dt between '2025-01-01' and '2025-12-31'
and CMPNY_CD in ('8000', '8545')
and (SLS_QTY_BEX IS NOT NULL AND SLS_QTY_BEX > 0)
group by all
;