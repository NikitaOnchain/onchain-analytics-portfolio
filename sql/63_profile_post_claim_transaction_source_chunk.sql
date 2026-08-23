-- Profile one materialized successful-transaction source chunk.
-- Update the table suffix and expected half-open UTC bounds together.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_01
--   Intended grain is one successful top-level transaction per hash.
--
-- Join keys and expected cardinality:
--   No JOIN is used. Candidate key is transaction_hash.
--
-- Filters and time boundaries:
--   The query verifies every row is within the half-open interval
--   [2023-03-23 00:00:00, 2023-03-27 00:00:00) UTC.
--
-- Row-multiplication risk:
--   None. Transaction uniqueness, source matches, valid source roles, block
--   consistency, and interval boundaries are measured explicitly.

SELECT
  COUNT(*) AS stored_transaction_rows,
  COUNT(DISTINCT transaction_hash) AS distinct_transaction_hashes,
  COUNT(*) - COUNT(DISTINCT transaction_hash)
    AS duplicate_rows_above_transaction_grain,
  COUNT(DISTINCT IF(
    initiated_by_claim_recipient,
    from_address,
    NULL
  )) AS distinct_claim_recipient_senders,
  COUNTIF(initiated_by_claim_recipient) AS claimant_initiated_rows,
  COUNTIF(is_claim_transaction) AS stored_claim_transaction_rows,
  COUNTIF(NOT initiated_by_claim_recipient AND NOT is_claim_transaction)
    AS rows_without_valid_source_role,
  COUNTIF(
    block_timestamp IS NULL
    OR block_number IS NULL
    OR block_hash IS NULL
    OR transaction_hash IS NULL
    OR transaction_index IS NULL
    OR from_address IS NULL
    OR gas_used IS NULL
  ) AS critical_null_rows,
  COUNTIF(receipt_match_rows IS NULL OR receipt_match_rows != 1)
    AS rows_without_exactly_one_receipt_match,
  COUNTIF(block_match_rows IS NULL OR block_match_rows != 1)
    AS rows_without_exactly_one_block_match,
  COUNTIF(block_timestamp != matched_block_timestamp)
    AS block_timestamp_mismatch_rows,
  COUNTIF(
    block_timestamp < TIMESTAMP('2023-03-23 00:00:00+00')
    OR block_timestamp >= TIMESTAMP('2023-03-27 00:00:00+00')
  ) AS rows_outside_expected_interval,
  MIN(block_timestamp) AS first_source_timestamp,
  MAX(block_timestamp) AS last_source_timestamp,
  MIN(block_number) AS first_block_number,
  MAX(block_number) AS last_block_number
FROM
  `YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_01`;
