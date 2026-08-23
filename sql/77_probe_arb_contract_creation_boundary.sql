-- Probe the possible top-level creation receipt for the verified ARB token.
-- Fresh-dry-run the exact statement before execution.
--
-- Output grain: exactly one summary row.
-- Source: Arbitrum receipts, intended one row per transaction hash.
-- Joins: none.
-- Filter: [2023-03-01, 2023-03-23) UTC and the verified ARB contract address.
-- Row-multiplication risk: none; duplicate receipt candidates remain counted.

WITH candidates AS (
  SELECT
    block_timestamp,
    block_hash,
    transaction_hash,
    transaction_index,
    COUNT(*) OVER (PARTITION BY transaction_hash) AS receipt_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.receipts`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-01 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-23 00:00:00+00')
    AND LOWER(contract_address) =
      '0x912ce59144191c1204e64559fe8253a0e49e6548'
)

SELECT
  COUNT(*) AS creation_candidate_rows,
  COUNTIF(receipt_match_rows != 1) AS non_unique_candidate_rows,
  ARRAY_AGG(
    STRUCT(
      block_timestamp,
      block_hash,
      transaction_hash,
      transaction_index,
      receipt_match_rows
    )
    ORDER BY block_timestamp, transaction_index, transaction_hash
    LIMIT 1
  )[SAFE_OFFSET(0)] AS first_creation_candidate
FROM
  candidates;
