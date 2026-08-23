-- Materialize compact exact claim-transaction ordering keys from one validated
-- successful-transaction source chunk. Update the target suffix, source table,
-- source chunk number, and coverage description together. Always dry-run the
-- exact statement before execution.
--
-- Configuration in this saved example:
--   Source/order chunk 21, half-open interval 2023-08-16 through
--   2023-09-01 UTC.
--
-- Output grain:
--   One successful exact claim transaction per unique transaction hash.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_21
--     One successful relevant top-level transaction per unique hash.
--
-- Join keys and expected cardinality:
--   No JOIN is used. Exact claim transactions are identified by the validated
--   source role flag.
--
-- Filters and time boundaries:
--   Only source chunk 21 rows flagged as exact claim transactions are retained.
--   The validated source table covers [2023-08-16, 2023-09-01) UTC.
--
-- Row-multiplication risk:
--   None inside this query. SQL 70 verifies uniqueness across every compact
--   order batch and reconciles coverage to eligible claim events.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.post_claim_transaction_order_batch_21`
CLUSTER BY
  claim_transaction_hash
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary compact exact claim-transaction ordering keys sourced from full post-claim transaction chunk 21.'
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
  `YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_21`
WHERE
  source_chunk_number = 21
  AND is_claim_transaction;

