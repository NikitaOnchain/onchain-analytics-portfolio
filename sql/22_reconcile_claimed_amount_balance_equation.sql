-- Reconcile the exact claimed ARB amount from independently selected
-- TokenDistributor balance components.
--
-- Output grain:
--   One reconciliation row.
--
-- Source inputs:
--   1. Initial positive ARB funding received before claims started, profiled
--      from decoded Transfer events.
--   2. Positive ARB inflows received after claims started and before the final
--      sweep, summed from non-overlapping interval profiles.
--   3. Final verified sweep amount to the configured sweep receiver.
--   4. Raw HasClaimed aggregate used only as the comparison target.
--
-- Join keys and expected cardinality:
--   No JOIN and no source-table scan. Each CTE contains one constant row.
--
-- Filters and time boundaries used to produce the inputs:
--   Initial funding: 2023-03-16 00:00:00 UTC to the first claim at
--   2023-03-23 13:01:22 UTC.
--   Return inflows: first claim through the sweep at
--   2023-09-25 02:20:03 UTC, using half-open interval scans.
--
-- Row-multiplication risk:
--   None. CROSS JOIN combines four one-row CTEs into one row.

WITH initial_funding AS (
  SELECT CAST('1162166000000000000000000000' AS BIGNUMERIC) AS amount_raw
),

positive_return_inflows AS (
  SELECT CAST('93885458006064728014866' AS BIGNUMERIC) AS amount_raw
),

final_sweep AS (
  SELECT CAST('69448385458006064728014866' AS BIGNUMERIC) AS amount_raw
),

raw_claim_profile AS (
  SELECT CAST('1092811500000000000000000000' AS BIGNUMERIC) AS amount_raw
)

SELECT
  initial_funding.amount_raw AS initial_funding_raw,
  positive_return_inflows.amount_raw AS positive_return_inflows_raw,
  final_sweep.amount_raw AS final_sweep_raw,
  initial_funding.amount_raw
    + positive_return_inflows.amount_raw
    - final_sweep.amount_raw AS balance_derived_claimed_raw,
  SAFE_DIVIDE(
    initial_funding.amount_raw
      + positive_return_inflows.amount_raw
      - final_sweep.amount_raw,
    CAST('1000000000000000000' AS BIGNUMERIC)
  ) AS balance_derived_claimed_arb,
  SAFE_DIVIDE(raw_claim_profile.amount_raw, initial_funding.amount_raw)
    AS funded_allocation_claim_rate,
  initial_funding.amount_raw - raw_claim_profile.amount_raw
    AS unclaimed_funded_allocation_raw,
  initial_funding.amount_raw
    + positive_return_inflows.amount_raw
    - final_sweep.amount_raw = raw_claim_profile.amount_raw
    AS exact_balance_match
FROM initial_funding
CROSS JOIN positive_return_inflows
CROSS JOIN final_sweep
CROSS JOIN raw_claim_profile;
