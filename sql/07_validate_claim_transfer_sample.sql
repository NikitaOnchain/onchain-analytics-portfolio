-- Validate decoded ARB transfers sent by the airdrop TokenDistributor.
-- Always dry-run this query before execution.
--
-- Purpose:
--   Confirm that decoded ARB Transfer rows provide stable sender, recipient,
--   and amount fields before profiling a transfer-based claim cohort.
--
-- Output grain:
--   One decoded ARB Transfer event. The candidate event key is
--   (transaction_hash, log_index).
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--   One source row represents one decoded event log.
--
-- Join keys and expected cardinality:
--   No JOIN.
--
-- Filters:
--   1. First UTC calendar day of the observed claim period
--   2. ARB token contract
--   3. Standard ERC-20 Transfer event signature
--   4. TokenDistributor as the decoded sender
--   5. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. A transaction can contain multiple transfers, which stay
--   distinct through log_index.
--
-- JSON decoding:
--   args[0] = sender, args[1] = recipient, args[2] = raw token amount.
--   This positional layout is provisional until broader samples are checked.
--
-- Official references (accessed 2026-08-11):
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema
--   https://arbiscan.io/token/0x912ce59144191c1204e64559fe8253a0e49e6548

WITH decoded_transfers AS (
  SELECT
    block_timestamp,
    transaction_hash,
    log_index,
    address,
    event_hash,
    event_signature,
    LOWER(JSON_VALUE(args, '$[0]')) AS sender,
    LOWER(JSON_VALUE(args, '$[1]')) AS recipient,
    SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC) AS amount_raw,
    removed
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-24 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
)

SELECT
  block_timestamp,
  transaction_hash,
  log_index,
  address,
  event_hash,
  event_signature,
  sender,
  recipient,
  amount_raw,
  SAFE_DIVIDE(amount_raw, CAST(POW(10, 18) AS BIGNUMERIC)) AS amount_arb
FROM
  decoded_transfers
WHERE
  sender = '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
ORDER BY
  block_timestamp,
  transaction_hash,
  log_index
LIMIT 10;
