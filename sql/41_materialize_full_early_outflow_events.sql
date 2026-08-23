-- Materialize full-cohort block-ordered positive ARB early-outflow events.
-- Always dry-run before execution.
--
-- Analytical meaning:
--   A matched row is a positive non-self ARB early-outflow event, not evidence
--   of a sale. Destinations remain unclassified.
--
-- Output grain:
--   One matched ARB Transfer event per unique claim recipient, identified by
--   (outflow_transaction_hash, outflow_log_index).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row. Only final
--     two-digit chunks are included.
--   YOUR_DATASET_ID.claimant_arb_transfer_source_chunk_*
--     One positive non-self claimant-originated ARB Transfer event per row.
--     Only final two-digit source chunks are included.
--
-- Join keys and expected cardinality:
--   claim.recipient = outflow.sender, expected one-to-many. Claim-recipient
--   uniqueness and staged event-key uniqueness were validated globally.
--
-- Filters and time boundaries:
--   1. Event is later than claim by (block_number, log_index)
--   2. Event timestamp is in [claim_timestamp, claim_timestamp + 7 days)
--   The staged source already enforces positive amount and non-self transfer.
--
-- Row-multiplication risk:
--   The join intentionally produces multiple event rows for claimants with
--   several outflows. Unique claim recipients prevent an event from matching
--   multiple claims; the follow-up profile checks global event-key uniqueness.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.early_outflow_events_full_cohort`
CLUSTER BY
  claim_recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary full-cohort block-ordered positive ARB early-outflow events within seven elapsed days.'
)
AS
WITH claims AS (
  SELECT
    chunk_number,
    block_timestamp AS claim_timestamp,
    block_number AS claim_block_number,
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    recipient AS claim_recipient,
    amount_raw AS claim_amount_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

outflow_source AS (
  SELECT
    source_chunk_number,
    block_timestamp AS outflow_timestamp,
    block_number AS outflow_block_number,
    transaction_hash AS outflow_transaction_hash,
    log_index AS outflow_log_index,
    sender,
    destination,
    amount_raw AS outflow_amount_raw,
    source_match_rows
  FROM
    `YOUR_DATASET_ID.claimant_arb_transfer_source_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
)

SELECT
  claim.chunk_number,
  claim.claim_timestamp,
  claim.claim_block_number,
  claim.claim_transaction_hash,
  claim.claim_log_index,
  claim.claim_recipient,
  claim.claim_amount_raw,
  outflow.source_chunk_number,
  outflow.outflow_timestamp,
  outflow.outflow_block_number,
  outflow.outflow_transaction_hash,
  outflow.outflow_log_index,
  outflow.destination,
  outflow.outflow_amount_raw,
  outflow.source_match_rows
FROM
  claims AS claim
INNER JOIN
  outflow_source AS outflow
  ON claim.claim_recipient = outflow.sender
WHERE
  (
    outflow.outflow_block_number > claim.claim_block_number
    OR (
      outflow.outflow_block_number = claim.claim_block_number
      AND outflow.outflow_log_index > claim.claim_log_index
    )
  )
  AND outflow.outflow_timestamp >= claim.claim_timestamp
  AND outflow.outflow_timestamp < TIMESTAMP_ADD(
    claim.claim_timestamp,
    INTERVAL 7 DAY
  );
