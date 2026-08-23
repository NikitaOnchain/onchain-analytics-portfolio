-- Profile the bounded event-level post-claim activity table for corrected
-- claim chunk 21.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.post_claim_activity_events_chunk_21
--   Intended grain is one successful post-claim top-level transaction per
--   claim recipient.
--
-- Join keys and expected cardinality:
--   No JOIN is used. The candidate key is activity_transaction_hash.
--
-- Filters and time boundaries:
--   No additional filter. The table already enforces block-aware order and the
--   half-open seven-elapsed-day window after each exact claim.
--
-- Row-multiplication risk:
--   None. Duplicate transaction hashes, source match counts, claim-receipt
--   consistency, ordering, and elapsed-window violations are measured.

SELECT
  COUNT(*) AS activity_transaction_rows,
  COUNT(DISTINCT activity_transaction_hash)
    AS distinct_activity_transaction_hashes,
  COUNT(*) - COUNT(DISTINCT activity_transaction_hash)
    AS duplicate_rows_above_activity_transaction_grain,
  COUNT(DISTINCT claim_recipient) AS active_claim_recipients,
  COUNTIF(
    claim_timestamp IS NULL
    OR claim_block_number IS NULL
    OR claim_block_hash IS NULL
    OR claim_transaction_hash IS NULL
    OR claim_transaction_index IS NULL
    OR claim_log_index IS NULL
    OR claim_recipient IS NULL
    OR claim_amount_raw IS NULL
    OR activity_timestamp IS NULL
    OR activity_block_number IS NULL
    OR activity_block_hash IS NULL
    OR activity_transaction_hash IS NULL
    OR activity_transaction_index IS NULL
    OR activity_gas_used IS NULL
  ) AS critical_null_rows,
  COUNTIF(
    claim_receipt_match_rows IS NULL
    OR claim_receipt_match_rows != 1
    OR activity_receipt_match_rows IS NULL
    OR activity_receipt_match_rows != 1
  ) AS rows_without_exactly_one_receipt_match,
  COUNTIF(
    claim_block_match_rows IS NULL
    OR claim_block_match_rows != 1
    OR activity_block_match_rows IS NULL
    OR activity_block_match_rows != 1
  ) AS rows_without_exactly_one_block_match,
  COUNTIF(claim_receipt_timestamp != claim_timestamp)
    AS claim_receipt_timestamp_mismatch_rows,
  COUNTIF(claim_receipt_block_number != claim_block_number)
    AS claim_receipt_block_mismatch_rows,
  COUNTIF(activity_transaction_hash = claim_transaction_hash)
    AS included_claim_transaction_rows,
  COUNTIF(
    activity_block_number < claim_block_number
    OR (
      activity_block_number = claim_block_number
      AND activity_transaction_index <= claim_transaction_index
    )
  ) AS transaction_order_violation_rows,
  COUNTIF(activity_timestamp < claim_timestamp)
    AS before_claim_timestamp_rows,
  COUNTIF(
    activity_timestamp >= TIMESTAMP_ADD(claim_timestamp, INTERVAL 7 DAY)
  ) AS outside_seven_day_window_rows,
  COUNTIF(activity_block_number = claim_block_number)
    AS same_block_ordered_activity_rows,
  COUNTIF(activity_to_address IS NULL AND created_contract_address IS NOT NULL)
    AS contract_creation_rows,
  COUNTIF(activity_to_address IS NULL AND created_contract_address IS NULL)
    AS rows_without_target_or_created_contract,
  COUNTIF(claim_transaction_sender != claim_recipient)
    AS activity_rows_for_delegated_claims,
  MIN(activity_timestamp) AS first_activity_timestamp,
  MAX(activity_timestamp) AS last_activity_timestamp
FROM
  `YOUR_DATASET_ID.post_claim_activity_events_chunk_21`;
