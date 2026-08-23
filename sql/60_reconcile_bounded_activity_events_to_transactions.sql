-- Reconcile every bounded post-claim activity event to the independent public
-- Arbitrum transactions table.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One aggregate reconciliation row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_activity_events_chunk_21
--     One validated successful post-claim transaction per row, sourced from
--     receipts plus blocks.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.transactions
--     Intended grain is one top-level transaction per transaction hash.
--
-- Join keys and expected cardinality:
--   stored.activity_transaction_hash = source.transaction_hash, expected
--   one-to-one after public-source pre-aggregation.
--
-- Filters and time boundaries:
--   The public transactions scan is restricted to the same half-open source
--   interval [2023-09-16, 2023-10-02) UTC used for bounded staging.
--
-- Row-multiplication risk:
--   The public source is pre-aggregated to transaction hash and retains a match
--   count. The LEFT JOIN preserves every stored event and exposes misses.

WITH stored_events AS (
  SELECT
    activity_timestamp,
    activity_block_hash,
    activity_transaction_hash,
    activity_transaction_index,
    claim_recipient AS activity_from_address,
    activity_to_address
  FROM
    `YOUR_DATASET_ID.post_claim_activity_events_chunk_21`
),

transaction_source AS (
  SELECT
    transaction_hash,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_hash) AS block_hash,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(LOWER(from_address)) AS from_address,
    ANY_VALUE(LOWER(to_address)) AS to_address,
    COUNT(*) AS source_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.transactions`
  WHERE
    block_timestamp >= TIMESTAMP('2023-09-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-10-02 00:00:00+00')
  GROUP BY
    transaction_hash
)

SELECT
  COUNT(*) AS stored_activity_event_rows,
  COUNT(DISTINCT stored.activity_transaction_hash)
    AS distinct_stored_activity_transaction_hashes,
  COUNTIF(source.transaction_hash IS NOT NULL) AS matched_transaction_rows,
  COUNTIF(source.transaction_hash IS NULL) AS unmatched_transaction_rows,
  COUNTIF(source.source_match_rows IS NULL OR source.source_match_rows != 1)
    AS rows_without_exactly_one_transaction_match,
  COUNTIF(stored.activity_timestamp != source.block_timestamp)
    AS timestamp_mismatch_rows,
  COUNTIF(stored.activity_block_hash != source.block_hash)
    AS block_hash_mismatch_rows,
  COUNTIF(stored.activity_transaction_index != source.transaction_index)
    AS transaction_index_mismatch_rows,
  COUNTIF(stored.activity_from_address != source.from_address)
    AS sender_mismatch_rows,
  COUNTIF(stored.activity_to_address IS DISTINCT FROM source.to_address)
    AS target_mismatch_rows
FROM
  stored_events AS stored
LEFT JOIN
  transaction_source AS source
  ON stored.activity_transaction_hash = source.transaction_hash;
