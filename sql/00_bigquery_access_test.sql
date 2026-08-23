-- BigQuery access test for the Google Blockchain Analytics Arbitrum dataset.
--
-- Purpose:
--   Verify that the public Arbitrum dataset is accessible and that a small,
--   time-bounded query returns understandable blockchain records.
--
-- Output grain:
--   One row per Arbitrum block, capped at 10 displayed rows.
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.blocks
--   One source row represents one Arbitrum block.
--
-- Join keys:
--   None. This query reads a single table and performs no JOIN.
--
-- Filters:
--   A half-open five-minute UTC interval on block_timestamp.
--   The table is monthly partitioned on block_timestamp.
--
-- Row-multiplication risk:
--   None from JOINs. block_timestamp is not unique because multiple Arbitrum
--   blocks can share the same timestamp; block_hash identifies the block.
--
-- Validation run (2026-08-11):
--   10 rows returned, 9.58 MB processed, and 10 MB billed.
--   This is an access test, not an analytical result for the ARB airdrop.
--
-- Official sources (accessed 2026-08-11):
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema
--   https://docs.cloud.google.com/blockchain-analytics/docs/example-arbitrum

SELECT
  block_timestamp,
  block_hash
FROM
  `bigquery-public-data.goog_blockchain_arbitrum_one_us.blocks`
WHERE
  block_timestamp >= TIMESTAMP('2023-03-23 12:00:00+00')
  AND block_timestamp < TIMESTAMP('2023-03-23 12:05:00+00')
ORDER BY
  block_timestamp
LIMIT 10;
