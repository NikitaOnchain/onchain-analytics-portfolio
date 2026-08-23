-- Materialize compact exact claim-transaction ordering keys from full post-
-- claim source chunks 01 through 20 before deleting those large source tables.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One successful exact claim transaction per unique transaction hash.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_*
--     One successful relevant top-level transaction per hash per source chunk.
--     Only final two-digit chunks 01 through 20 are currently present.
--
-- Join keys and expected cardinality:
--   No JOIN is used. Transaction hashes must already be globally unique across
--   the non-overlapping source chunks.
--
-- Filters and time boundaries:
--   Only rows flagged as exact validated claim transactions are retained from
--   source coverage [2023-03-23, 2023-08-16) UTC.
--
-- Row-multiplication risk:
--   None. Follow-up QA checks transaction-hash uniqueness and claim-event
--   coverage separately because one transaction can contain several claims.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.post_claim_transaction_order_batch_01_20`
CLUSTER BY
  claim_transaction_hash
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary compact exact claim-transaction ordering keys sourced from full post-claim transaction chunks 01 through 20.'
)
AS
SELECT
  source_chunk_number,
  block_timestamp AS claim_receipt_timestamp,
  block_number AS claim_receipt_block_number,
  block_hash AS claim_block_hash,
  transaction_hash AS claim_transaction_hash,
  transaction_index AS claim_transaction_index,
  from_address AS claim_transaction_sender,
  receipt_match_rows AS claim_receipt_match_rows,
  block_match_rows AS claim_block_match_rows
FROM
  `YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_*`
WHERE
  REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
  AND source_chunk_number BETWEEN 1 AND 20
  AND is_claim_transaction;

