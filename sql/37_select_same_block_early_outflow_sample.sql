-- Select the earliest deterministic same-block early-outflow event from the
-- bounded chunk-21 event table.
-- Always dry-run before execution.
--
-- Output grain:
--   One same-block claimant-outflow event pair.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.early_outflow_events_chunk_21
--   One validated positive non-self outflow event per row.
--
-- Join keys and expected cardinality:
--   No JOIN.
--
-- Filters and time boundaries:
--   The stored event must share the claim block and have a larger block-global
--   log index. The table already enforces the elapsed seven-day window.
--
-- Row-multiplication risk:
--   None. QUALIFY retains exactly one deterministic event.

SELECT
  claim_recipient,
  claim_timestamp,
  claim_block_number,
  claim_transaction_hash,
  claim_log_index,
  claim_amount_raw / POW(CAST(10 AS BIGNUMERIC), 18)
    AS claim_amount_arb,
  outflow_timestamp,
  outflow_block_number,
  outflow_transaction_hash,
  outflow_log_index,
  destination,
  outflow_amount_raw / POW(CAST(10 AS BIGNUMERIC), 18)
    AS outflow_amount_arb,
  TIMESTAMP_DIFF(outflow_timestamp, claim_timestamp, SECOND)
    AS seconds_after_claim_timestamp
FROM
  `YOUR_DATASET_ID.early_outflow_events_chunk_21`
WHERE
  outflow_block_number = claim_block_number
  AND outflow_log_index > claim_log_index
QUALIFY
  ROW_NUMBER() OVER (
    ORDER BY
      claim_timestamp,
      claim_recipient,
      outflow_log_index
  ) = 1;
