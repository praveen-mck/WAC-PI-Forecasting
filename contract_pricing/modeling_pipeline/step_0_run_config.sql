-- =========================================================
-- STEP 0: BACKTEST RUN CONFIGURATION v23
--
-- Single source of truth for all backtest run IDs and their
-- date boundaries. Every downstream bt step reads from this
-- table — adding a new run requires only a UNION ALL block here.
--
-- Columns:
--   run_id                  — unique identifier, e.g. 'BT_2025_01'
--   jump_off_month          — first forecast month (1st of month)
--   lookback_years          — years of history used for training
--   history_start_dt        — first day of training window
--   history_end_dt          — last day of training window (= jump_off - 1 day)
--   forecast_horizon_end_dt — last month of evaluation window (2 yrs out)
--
-- Prerequisites: none — run this before all other bt steps.
-- =========================================================

CREATE OR REPLACE TABLE uspd_analytics_den.analytics_gold.contract_price_bt_runs_v23 AS

-- ── To add a new run: copy one block below and update the 3 values ──────────
--    run_id        → 'BT_YYYY_MM'  (year + zero-padded month of jump-off)
--    jump_off_date → 'YYYY-MM-01'  (first day of the jump-off month)
--    lookback_yrs  → integer years of history to include

SELECT
    'BT_2024_01'                                          AS run_id,
    TO_DATE('2024-01-01')                                 AS jump_off_month,
    2                                                     AS lookback_years,
    ADD_MONTHS(TO_DATE('2024-01-01'), -24)                AS history_start_dt,
    DATE_SUB(TO_DATE('2024-01-01'), 1)                    AS history_end_dt,
    ADD_MONTHS(TO_DATE('2024-01-01'), 24)                 AS forecast_horizon_end_dt

UNION ALL

SELECT
    'BT_2024_04'                                          AS run_id,
    TO_DATE('2024-04-01')                                 AS jump_off_month,
    2                                                     AS lookback_years,
    ADD_MONTHS(TO_DATE('2024-04-01'), -24)                AS history_start_dt,
    DATE_SUB(TO_DATE('2024-04-01'), 1)                    AS history_end_dt,
    ADD_MONTHS(TO_DATE('2024-04-01'), 24)                 AS forecast_horizon_end_dt

UNION ALL

SELECT
    'BT_2025_01'                                          AS run_id,
    TO_DATE('2025-01-01')                                 AS jump_off_month,
    1                                                     AS lookback_years,
    ADD_MONTHS(TO_DATE('2025-01-01'), -12)                AS history_start_dt,
    DATE_SUB(TO_DATE('2025-01-01'), 1)                    AS history_end_dt,
    ADD_MONTHS(TO_DATE('2025-01-01'), 24)                 AS forecast_horizon_end_dt

-- ── Add new runs below ────────────────────────────────────────────────────────
-- july 2026 for odyssey
UNION ALL
SELECT
    'BT_2026_07'                                          AS run_id,
    TO_DATE('2026-07-01')                                 AS jump_off_month,
    1                                                     AS lookback_years,
    ADD_MONTHS(TO_DATE('2026-07-01'), -12)                AS history_start_dt,
    DATE_SUB(TO_DATE('2026-07-01'), 1)                    AS history_end_dt,
    ADD_MONTHS(TO_DATE('2026-07-01'), 24)                 AS forecast_horizon_end_dt
-- ── Add new runs below ────────────────────────────────────────────────────────
--consolidated view 

UNION ALL
SELECT
    'BT_2025_08'                                          AS run_id,
    TO_DATE('2025-08-01')                                 AS jump_off_month,
    1                                                     AS lookback_years,
    ADD_MONTHS(TO_DATE('2025-08-01'), -12)                AS history_start_dt,
    DATE_SUB(TO_DATE('2025-08-01'), 1)                    AS history_end_dt,
    ADD_MONTHS(TO_DATE('2025-08-01'), 60)                 AS forecast_horizon_end_dt



-- ── Add new runs below ────────────────────────────────────────────────────────
-- UNION ALL
-- SELECT
--     'BT_2025_04'                                          AS run_id,
--     TO_DATE('2025-04-01')                                 AS jump_off_month,
--     1                                                     AS lookback_years,
--     ADD_MONTHS(TO_DATE('2025-04-01'), -12)                AS history_start_dt,
--     DATE_SUB(TO_DATE('2025-04-01'), 1)                    AS history_end_dt,
--     ADD_MONTHS(TO_DATE('2025-04-01'), 24)                 AS forecast_horizon_end_dt
;