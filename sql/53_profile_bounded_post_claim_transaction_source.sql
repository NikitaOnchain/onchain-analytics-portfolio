-- Profile the bounded successful-transaction source for corrected claim
-- chunk 21 before deriving any post-claim activity metric.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One QA summary row for the staged transaction source.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_transaction_source_chunk_21
--     Intended grain is one successful top-level transaction per transaction
--     hash that is claimant-initiated or an exact chunk-21 claim transaction.
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21
--     One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   claim.transaction_hash = source.transaction_hash in scalar claim coverage
--   checks, expected one source row for every claim. No JOIN affects the main
--   transaction-source profile.
--
-- Filters and time boundaries:
--   The staged table is already restricted to successful receipts in the
--   half-open source interval [2023-09-16, 2023-10-02) UTC.
--
-- Row-multiplication risk:
--   None in the main profile. Duplicate transaction hashes and source match
--   counts are measured explicitly. Claim coverage uses COUNTIF over an EXISTS
--   predicate, so it cannot multiply claim rows.

WITH source AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_source_chunk_21`
),

claims AS (
  SELECT
    transaction_hash AS claim_transaction_hash,
    recipient AS claim_recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21`
)

SELECT
  COUNT(*) AS transaction_rows,
  COUNT(DISTINCT transaction_hash) AS distinct_transaction_hashes,
  COUNT(*) - COUNT(DISTINCT transaction_hash)
    AS duplicate_rows_above_transaction_grain,
  COUNT(DISTINCT from_address) AS distinct_claim_recipient_senders,
  COUNTIF(initiated_by_claim_recipient) AS claimant_initiated_rows,
  COUNTIF(is_claim_transaction) AS stored_claim_transaction_rows,
  COUNTIF(is_claim_transaction AND NOT initiated_by_claim_recipient)
    AS claim_rows_not_initiated_by_any_chunk_recipient,
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
    block_timestamp < TIMESTAMP('2023-09-16 00:00:00+00')
    OR block_timestamp >= TIMESTAMP('2023-10-02 00:00:00+00')
  ) AS rows_outside_source_interval,
  (
    SELECT COUNTIF(NOT EXISTS (
      SELECT 1
      FROM source
      WHERE source.transaction_hash = claim.claim_transaction_hash
        AND source.is_claim_transaction
    ))
    FROM claims AS claim
  ) AS claim_transactions_missing_from_source,
  MIN(block_timestamp) AS first_source_timestamp,
  MAX(block_timestamp) AS last_source_timestamp
FROM
  source;
