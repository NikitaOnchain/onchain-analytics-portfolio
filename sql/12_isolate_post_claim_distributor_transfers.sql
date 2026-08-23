-- Isolate decoded ARB transfers sent by the TokenDistributor after the last
-- observed raw HasClaimed event. Dry-run before execution.
--
-- Purpose:
--   Identify the candidate non-claim transfer responsible for the full-window
--   reconciliation difference between decoded transfers and raw HasClaimed.
--
-- Output grain:
--   One row per decoded ARB Transfer event after the raw claim window.
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
--   1. Strictly after the last observed raw HasClaimed timestamp
--   2. Before the end of the final scan interval
--   3. ARB token contract
--   4. Standard ERC-20 Transfer event signature
--   5. TokenDistributor as the decoded sender
--   6. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. Every returned row remains at decoded event-log grain.
--
-- Important interpretation rule:
--   A post-claim-window transfer is a candidate non-claim transfer. Its purpose
--   must not be classified until the transaction is manually verified.

WITH decoded_transfers AS (
  SELECT
    block_number,
    block_timestamp,
    transaction_hash,
    log_index,
    LOWER(JSON_VALUE(args, '$[0]')) AS sender,
    LOWER(JSON_VALUE(args, '$[1]')) AS recipient,
    SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC) AS amount_raw
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp > TIMESTAMP('2023-09-24 20:12:52+00')
    AND block_timestamp < TIMESTAMP('2023-10-01 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
)

SELECT
  block_number,
  block_timestamp,
  transaction_hash,
  log_index,
  sender,
  recipient,
  amount_raw,
  SAFE_DIVIDE(
    amount_raw,
    CAST('1000000000000000000' AS BIGNUMERIC)
  ) AS amount_arb
FROM
  decoded_transfers
WHERE
  sender = '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
ORDER BY
  block_timestamp,
  transaction_hash,
  log_index;
