-- Materialize one remaining block-enriched corrected claim-transfer chunk.
-- Always update the target/source suffix and both time bounds together, then
-- dry-run the resulting statement immediately before execution.
--
-- Configuration in this saved example:
--   Chunk 02, half-open UTC interval 2023-03-27 through 2023-04-01.
--
-- Output grain:
--   One validated claim Transfer event per row, identified by
--   (transaction_hash, log_index).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_chunk_02
--     One validated claim Transfer event per row.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One decoded event log per row.
--
-- Join keys and expected cardinality:
--   LEFT JOIN on (transaction_hash, log_index), expected one-to-one. The public
--   source is first aggregated to one row per event key. `source_match_rows` is
--   retained for downstream coverage and cardinality checks.
--
-- Filters and time boundaries:
--   1. The configured half-open UTC chunk interval
--   2. ARB token contract and standard Transfer event
--   3. TokenDistributor as decoded sender
--   4. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   Controlled by pre-aggregating the public source at the exact event key.
--   Every materialized chunk must be profiled before it is accepted.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_02`
CLUSTER BY
  recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary corrected ARB claim-transfer chunk enriched with claim block number.'
)
AS
WITH source_claim_transfers AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(block_number) AS block_number,
    COUNT(*) AS source_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-27 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-04-01 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND LOWER(JSON_VALUE(args, '$[0]')) =
      '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
    AND removed IS NOT TRUE
  GROUP BY
    transaction_hash,
    log_index
)

SELECT
  claim.chunk_number,
  claim.block_timestamp,
  source.block_number,
  claim.transaction_hash,
  claim.log_index,
  claim.recipient,
  claim.amount_raw,
  source.source_match_rows
FROM
  `YOUR_DATASET_ID.corrected_claim_transfers_chunk_02` AS claim
LEFT JOIN
  source_claim_transfers AS source
  USING (transaction_hash, log_index);
