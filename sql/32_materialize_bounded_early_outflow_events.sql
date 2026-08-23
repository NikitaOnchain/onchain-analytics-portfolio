-- Materialize block-ordered positive early-outflow events for corrected claim
-- chunk 21 within seven elapsed days after each claim.
-- Always dry-run before execution.
--
-- Analytical meaning:
--   A matched row is an ARB early-outflow event, not evidence of a sale. No DEX
--   swap or reliably labeled exchange destination is inferred here.
--
-- Output grain:
--   One matched positive non-self ARB Transfer event per claim recipient,
--   identified by (outflow_transaction_hash, outflow_log_index).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21
--     One validated claim Transfer event and unique recipient per row.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One decoded event log per row.
--
-- Join keys and expected cardinality:
--   claim.recipient = outflow.sender, expected one-to-many. The public event
--   source is pre-aggregated to one row per (transaction_hash, log_index), and
--   `source_match_rows` is retained to expose source duplicates.
--
-- Filters and time boundaries:
--   1. Public-source scan: 2023-09-16 through 2023-10-02 UTC, half-open
--   2. ARB Transfer events that are not marked removed
--   3. Positive amounts and destination different from sender
--   4. Event occurs after claim by (block_number, log_index)
--   5. Event timestamp is in [claim_timestamp, claim_timestamp + 7 days)
--
-- Row-multiplication risk:
--   The claim-to-outflow join intentionally creates multiple rows per claimant.
--   Claim recipients are unique in the validated cohort, while source event-key
--   pre-aggregation prevents duplicate decoded rows from multiplying the join.
--   The follow-up profile verifies outflow event-key uniqueness and cardinality.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.early_outflow_events_chunk_21`
CLUSTER BY
  claim_recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary block-ordered positive ARB early-outflow events for corrected claim chunk 21.'
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
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21`
),

outflow_source AS (
  SELECT
    transaction_hash AS outflow_transaction_hash,
    log_index AS outflow_log_index,
    ANY_VALUE(block_timestamp) AS outflow_timestamp,
    ANY_VALUE(block_number) AS outflow_block_number,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[0]'))) AS sender,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[1]'))) AS destination,
    ANY_VALUE(
      SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC)
    ) AS outflow_amount_raw,
    COUNT(*) AS source_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-09-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-10-02 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
  GROUP BY
    transaction_hash,
    log_index
)

SELECT
  claim.chunk_number,
  claim.claim_timestamp,
  claim.claim_block_number,
  claim.claim_transaction_hash,
  claim.claim_log_index,
  claim.claim_recipient,
  claim.claim_amount_raw,
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
  outflow.outflow_amount_raw > 0
  AND outflow.destination != claim.claim_recipient
  AND (
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
