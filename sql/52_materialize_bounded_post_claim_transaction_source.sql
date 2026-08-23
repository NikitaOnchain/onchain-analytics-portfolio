-- Materialize successful Arbitrum transactions initiated by claim recipients
-- in corrected claim chunk 21 across the bounded seven-day source interval.
-- Always dry-run the exact statement before execution.
--
-- Analytical meaning:
--   A row is claimant-address transaction activity. It is not necessarily a
--   protocol interaction, retained human usage, an ARB transfer, or a sale.
--   The source intentionally includes each exact claim transaction, including
--   claims submitted by a different sender, so its transaction index can be
--   validated and used for block-aware ordering.
--
-- Output grain:
--   One successful top-level Arbitrum transaction per unique transaction hash
--   that was either initiated by a corrected chunk-21 claim recipient or is an
--   exact chunk-21 claim transaction.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21
--     One validated claim event and unique recipient per row.
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
--   Both public sources are pre-aggregated to their intended keys. Match counts
--   are retained so duplicate source rows cannot silently multiply the result.
--
-- Filters and time boundaries:
--   Public tables are restricted to the half-open interval
--   [2023-09-16 00:00:00 UTC, 2023-10-02 00:00:00 UTC), which covers every
--   chunk-21 claim and its first seven elapsed days.
--   Only receipts with status = 1 and a non-null sender are retained.
--
-- Row-multiplication risk:
--   A claimant can initiate many transactions, which is intentional. Distinct
--   claim-side key sets prevent multiplication when one receipt matches both
--   roles. The follow-up profile verifies source match counts.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.post_claim_transaction_source_chunk_21`
CLUSTER BY
  from_address
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary successful transaction source for bounded chunk-21 post-claim activity validation.'
)
AS
WITH claims AS (
  SELECT
    transaction_hash AS claim_transaction_hash,
    LOWER(recipient) AS recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21`
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
    block_timestamp >= TIMESTAMP('2023-09-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-10-02 00:00:00+00')
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
    block_timestamp >= TIMESTAMP('2023-09-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-10-02 00:00:00+00')
  GROUP BY
    block_hash
)

SELECT
  21 AS claim_chunk_number,
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
