-- Materialize one non-overlapping interval of successful transactions that are
-- relevant to the validated claim cohort.
-- Always update the target chunk number and both UTC bounds together, then
-- dry-run the exact statement immediately before execution.
--
-- Configuration in this saved example:
--   Source chunk 01, half-open interval 2023-03-23 through 2023-03-27 UTC.
--
-- Analytical meaning:
--   A row is either a successful top-level transaction initiated by a claim
--   recipient or an exact claim transaction. It is address activity, not proof
--   of retained human usage, protocol engagement, token retention, or a sale.
--
-- Output grain:
--   One successful top-level Arbitrum transaction per transaction hash.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row. Only final
--     two-digit claim chunks are included.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.receipts
--     Intended grain is one transaction receipt per transaction hash.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.blocks
--     Intended grain is one block per block hash.
--
-- Join keys and expected cardinality:
--   receipt.from_address = claim_sender.recipient, expected many-to-one.
--   receipt.transaction_hash = claim_transaction.transaction_hash, expected
--   many-to-one because both claim-side key sets are deduplicated first.
--   receipt.block_hash = block.block_hash, expected many-to-one.
--   Public sources are pre-aggregated and retain source match counts.
--
-- Filters and time boundaries:
--   Public tables use [2023-03-23 00:00:00, 2023-03-27 00:00:00) UTC.
--   Only successful receipts (status = 1) with non-null sender are retained.
--
-- Row-multiplication risk:
--   Distinct claim-side keys and public-source pre-aggregation prevent
--   accidental many-to-many multiplication. Per-chunk and global QA verify
--   transaction uniqueness, source matches, roles, and interval boundaries.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_01`
CLUSTER BY
  from_address
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary successful transaction source for full-cohort post-claim activity, source chunk 01.'
)
AS
WITH claims AS (
  SELECT
    transaction_hash AS claim_transaction_hash,
    LOWER(recipient) AS recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

claim_senders AS (
  SELECT DISTINCT
    recipient
  FROM
    claims
),

claim_transactions AS (
  SELECT DISTINCT
    claim_transaction_hash
  FROM
    claims
),

receipt_source AS (
  SELECT
    transaction_hash,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_hash) AS block_hash,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(LOWER(from_address)) AS from_address,
    ANY_VALUE(LOWER(to_address)) AS to_address,
    ANY_VALUE(LOWER(contract_address)) AS contract_address,
    ANY_VALUE(gas_used) AS gas_used,
    COUNT(*) AS receipt_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.receipts`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-27 00:00:00+00')
    AND status = 1
    AND from_address IS NOT NULL
  GROUP BY
    transaction_hash
),

block_source AS (
  SELECT
    block_hash,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    COUNT(*) AS block_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.blocks`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-27 00:00:00+00')
  GROUP BY
    block_hash
)

SELECT
  1 AS source_chunk_number,
  receipt.block_timestamp,
  block.block_number,
  receipt.block_hash,
  receipt.transaction_hash,
  receipt.transaction_index,
  receipt.from_address,
  receipt.to_address,
  receipt.contract_address,
  receipt.gas_used,
  claim_sender.recipient IS NOT NULL AS initiated_by_claim_recipient,
  claim_transaction.claim_transaction_hash IS NOT NULL
    AS is_claim_transaction,
  receipt.receipt_match_rows,
  block.block_match_rows,
  block.block_timestamp AS matched_block_timestamp
FROM
  receipt_source AS receipt
LEFT JOIN
  block_source AS block
  USING (block_hash)
LEFT JOIN
  claim_senders AS claim_sender
  ON receipt.from_address = claim_sender.recipient
LEFT JOIN
  claim_transactions AS claim_transaction
  ON receipt.transaction_hash = claim_transaction.claim_transaction_hash
WHERE
  claim_sender.recipient IS NOT NULL
  OR claim_transaction.claim_transaction_hash IS NOT NULL;
