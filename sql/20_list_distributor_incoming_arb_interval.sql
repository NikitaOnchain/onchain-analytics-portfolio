-- List ARB Transfer events received by the airdrop TokenDistributor during one
-- partition-bounded interval. Update both timestamp literals together and
-- always dry-run before execution.
--
-- Purpose:
--   Support an independent balance-equation check of the claimed aggregate:
--   distributor inflows - final sweep - other verified outflows = claims.
--
-- Output grain:
--   One row per decoded ERC-20 Transfer event received by the distributor.
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
--   4. TokenDistributor as the decoded recipient
--   5. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. Duplicate source rows remain visible at the candidate
--   event key and are checked in the reconciliation query.
--
-- JSON decoding:
--   args[0] = sender, args[1] = recipient, args[2] = raw token amount.
--
-- Official references (accessed 2026-08-13):
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema
--   https://arbiscan.io/token/0x912ce59144191c1204e64559fe8253a0e49e6548

SELECT
  block_number,
  block_timestamp,
  transaction_hash,
  log_index,
  LOWER(JSON_VALUE(args, '$[0]')) AS sender,
  LOWER(JSON_VALUE(args, '$[1]')) AS recipient,
  SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC) AS amount_raw,
  SAFE_DIVIDE(
    SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC),
    CAST('1000000000000000000' AS BIGNUMERIC)
  ) AS amount_arb
FROM
  `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
WHERE
  block_timestamp >= TIMESTAMP('2023-03-16 00:00:00+00')
  AND block_timestamp < TIMESTAMP('2023-03-23 13:01:22+00')
  AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
  AND event_signature = 'Transfer(address,address,uint256)'
  AND LOWER(JSON_VALUE(args, '$[1]')) =
    '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
  AND removed IS NOT TRUE
ORDER BY
  block_timestamp,
  transaction_hash,
  log_index;
