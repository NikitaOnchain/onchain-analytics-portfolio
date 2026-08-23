-- List candidate early ARB outflow events for one manually validated claim
-- recipient during the first 24 hours after the claim.
--
-- Output grain:
--   One row per decoded ARB Transfer event sent by the sampled recipient.
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--   One source row represents one decoded event log.
--
-- Candidate event key:
--   (transaction_hash, log_index).
--
-- Join keys and expected cardinality:
--   No JOIN. The claim recipient and timestamp are fixed sample parameters.
--
-- Filters and time boundaries:
--   1. Strictly after the sampled claim timestamp
--   2. Through 24 hours after that timestamp, inclusive
--   3. ARB token contract and standard Transfer event
--   4. Sampled claimant as decoded sender
--   5. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. Multiple returned rows are expected because one wallet
--   can send several transfers. Zero-value events remain visible for QA.
--
-- Interpretation rule:
--   These events are candidate early outflows, not demonstrated sales. A DEX
--   swap or reliably labeled exchange destination requires separate evidence.

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
  block_timestamp > TIMESTAMP('2023-03-23 13:01:22+00')
  AND block_timestamp <= TIMESTAMP('2023-03-24 13:01:22+00')
  AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
  AND event_signature = 'Transfer(address,address,uint256)'
  AND LOWER(JSON_VALUE(args, '$[0]')) =
    '0x27a1b27b2e8bfdd57a3049415dcf6a63ac11667f'
  AND removed IS NOT TRUE
ORDER BY
  block_number,
  log_index
LIMIT 20;
