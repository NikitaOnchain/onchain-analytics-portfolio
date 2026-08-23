-- Materialize block-ordered successful post-claim transactions for corrected
-- claim chunk 21 within seven elapsed days after each claim.
-- Always dry-run the exact statement before execution.
--
-- Analytical meaning:
--   A matched row is a successful top-level transaction initiated by a claim
--   recipient after that recipient's claim. It is an address-activity measure,
--   not proof of retained human usage, protocol engagement, or a sale.
--
-- Output grain:
--   One successful post-claim transaction per unique claim recipient, keyed by
--   activity_transaction_hash. Claim recipients are unique and each top-level
--   transaction has one sender, so the transaction hash should also be unique.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21
--     One validated claim event and unique recipient per row.
--   YOUR_DATASET_ID.post_claim_transaction_source_chunk_21
--     One successful top-level transaction per transaction hash that is either
--     claimant-initiated or an exact chunk-21 claim transaction.
--
-- Join keys and expected cardinality:
--   claim.claim_transaction_hash = source.transaction_hash, many-to-one from
--   claims because several claim events can occur in one transaction.
--   claim.claim_recipient = activity.from_address, expected one-to-many.
--
-- Filters and time boundaries:
--   1. Activity source row was initiated by a chunk-21 claim recipient.
--   2. Claim transaction itself is excluded for that recipient.
--   3. Activity is later by (block_number, transaction_index).
--   4. Activity timestamp is in the half-open elapsed interval
--      [claim_timestamp, claim_timestamp + 7 days).
--
-- Row-multiplication risk:
--   Claim-to-activity matching intentionally creates multiple rows per active
--   recipient. Unique recipients and source transaction hashes prevent a
--   transaction from matching multiple claims. Follow-up QA verifies the key.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.post_claim_activity_events_chunk_21`
CLUSTER BY
  claim_recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary block-ordered successful post-claim transaction events for corrected claim chunk 21.'
)
AS
WITH claims AS (
  SELECT
    chunk_number,
    block_timestamp AS claim_timestamp,
    block_number AS claim_block_number,
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    LOWER(recipient) AS claim_recipient,
    amount_raw AS claim_amount_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21`
),

source AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_source_chunk_21`
),

claims_with_receipt AS (
  SELECT
    claim.*,
    receipt.block_timestamp AS claim_receipt_timestamp,
    receipt.block_number AS claim_receipt_block_number,
    receipt.block_hash AS claim_block_hash,
    receipt.transaction_index AS claim_transaction_index,
    receipt.from_address AS claim_transaction_sender,
    receipt.receipt_match_rows AS claim_receipt_match_rows,
    receipt.block_match_rows AS claim_block_match_rows
  FROM
    claims AS claim
  INNER JOIN
    source AS receipt
    ON claim.claim_transaction_hash = receipt.transaction_hash
)

SELECT
  claim.chunk_number,
  claim.claim_timestamp,
  claim.claim_block_number,
  claim.claim_block_hash,
  claim.claim_transaction_hash,
  claim.claim_transaction_index,
  claim.claim_log_index,
  claim.claim_recipient,
  claim.claim_transaction_sender,
  claim.claim_amount_raw,
  claim.claim_receipt_timestamp,
  claim.claim_receipt_block_number,
  claim.claim_receipt_match_rows,
  claim.claim_block_match_rows,
  activity.block_timestamp AS activity_timestamp,
  activity.block_number AS activity_block_number,
  activity.block_hash AS activity_block_hash,
  activity.transaction_hash AS activity_transaction_hash,
  activity.transaction_index AS activity_transaction_index,
  activity.to_address AS activity_to_address,
  activity.contract_address AS created_contract_address,
  activity.gas_used AS activity_gas_used,
  activity.receipt_match_rows AS activity_receipt_match_rows,
  activity.block_match_rows AS activity_block_match_rows
FROM
  claims_with_receipt AS claim
INNER JOIN
  source AS activity
  ON claim.claim_recipient = activity.from_address
WHERE
  activity.initiated_by_claim_recipient
  AND activity.transaction_hash != claim.claim_transaction_hash
  AND (
    activity.block_number > claim.claim_block_number
    OR (
      activity.block_number = claim.claim_block_number
      AND activity.transaction_index > claim.claim_transaction_index
    )
  )
  AND activity.block_timestamp >= claim.claim_timestamp
  AND activity.block_timestamp < TIMESTAMP_ADD(
    claim.claim_timestamp,
    INTERVAL 7 DAY
  );

