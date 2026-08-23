-- Materialize one partition-bounded corrected claim-transfer interval as an
-- expiring BigQuery table. Dry-run after changing the configuration.
--
-- Sandbox compatibility:
--   BigQuery Sandbox does not allow DML INSERT statements. Each interval is
--   therefore written with CREATE OR REPLACE TABLE AS SELECT (CTAS), and the
--   final QA query reads all interval tables through a wildcard.
--
-- Configuration:
--   Update the two-digit target-table suffix, chunk number, and both timestamp
--   bounds together.
--
-- Output and target grain:
--   One stored row per decoded Transfer event in the configured interval.
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--   One source row represents one decoded event log.
--
-- Candidate event key:
--   (transaction_hash, log_index).
--
-- Join keys and expected cardinality:
--   No JOIN.
--
-- Filters:
--   1. Configured half-open UTC interval
--   2. ARB token contract
--   3. Standard ERC-20 Transfer event signature
--   4. TokenDistributor as the decoded sender
--   5. Rows that are not marked as removed
--   6. The manually verified post-claim sweep transaction is excluded
--
-- Row-multiplication risk:
--   None from JOINs. Source duplicates are preserved for global QA at the
--   candidate event key.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.corrected_claim_transfers_chunk_21`
CLUSTER BY
  recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
)
AS
WITH decoded_transfers AS (
  SELECT
    block_timestamp,
    transaction_hash,
    log_index,
    LOWER(JSON_VALUE(args, '$[0]')) AS sender,
    LOWER(JSON_VALUE(args, '$[1]')) AS recipient,
    SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC) AS amount_raw
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-09-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-10-01 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
)
SELECT
  21 AS chunk_number,
  block_timestamp,
  transaction_hash,
  log_index,
  recipient,
  amount_raw
FROM
  decoded_transfers
WHERE
  sender = '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
  AND transaction_hash != '0xa2477f2f1d7824501520a88b50835ad283e7472e0fa5e67005452528bf740175';
