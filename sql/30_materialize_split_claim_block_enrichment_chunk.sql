-- Materialize one time-bounded part of a block-enriched corrected claim chunk.
-- Always update the target suffix, source chunk suffix, and both time bounds
-- together, then dry-run immediately before execution.
--
-- Configuration in this saved example:
--   First part of chunk 05, 2023-04-13 through 2023-04-16 UTC.
--
-- Output grain:
--   One validated claim Transfer event per row within the configured subrange,
--   identified by (transaction_hash, log_index).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_chunk_05
--     One validated claim Transfer event per row.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One decoded event log per row.
--
-- Join keys and expected cardinality:
--   LEFT JOIN on (transaction_hash, log_index), expected one-to-one. The public
--   source is pre-aggregated at this event key and retains `source_match_rows`.
--
-- Filters and time boundaries:
--   The same half-open UTC subrange is applied to both sources. The public
--   source is additionally restricted to ARB Transfer events from the
--   TokenDistributor that are not marked removed.
--
-- Row-multiplication risk:
--   Controlled by public-source pre-aggregation. Split outputs must be profiled
--   separately and again after UNION ALL into the final two-digit chunk table.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_05a`
CLUSTER BY
  recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary split part of corrected ARB claim-transfer block enrichment.'
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
    block_timestamp >= TIMESTAMP('2023-04-13 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-04-16 00:00:00+00')
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
  `YOUR_DATASET_ID.corrected_claim_transfers_chunk_05` AS claim
LEFT JOIN
  source_claim_transfers AS source
  USING (transaction_hash, log_index)
WHERE
  claim.block_timestamp >= TIMESTAMP('2023-04-13 00:00:00+00')
  AND claim.block_timestamp < TIMESTAMP('2023-04-16 00:00:00+00');
