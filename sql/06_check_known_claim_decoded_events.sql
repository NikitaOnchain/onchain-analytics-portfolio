-- Check decoded_events coverage for one manually validated claim transaction.
-- Review the BigQuery dry-run estimate before execution.
--
-- Purpose:
--   Determine whether the known claim transaction exists in decoded_events
--   without relying on the TokenDistributor address format. This separates an
--   address-normalization issue from missing decoded-event coverage.
--
-- Output grain:
--   One decoded event row from the known transaction. The candidate event key
--   is (transaction_hash, log_index).
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
--   2. One transaction hash manually validated on Arbiscan
--   3. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. Multiple decoded events in the transaction are expected
--   and remain distinct through log_index.
--
-- Manual reference (accessed 2026-08-11):
--   https://arbiscan.io/tx/0x324f2ef46287a4f51a70e2a17ecd9a68af8f4c94c1eed0da16fa1e20992cb15a

SELECT
  block_timestamp,
  transaction_hash,
  log_index,
  address,
  event_hash,
  event_signature,
  args,
  removed
FROM
  `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
WHERE
  block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
  AND block_timestamp < TIMESTAMP('2023-03-24 00:00:00+00')
  AND transaction_hash = LOWER(
    '0x324f2ef46287a4f51a70e2a17ecd9a68af8f4c94c1eed0da16fa1e20992cb15a'
  )
  AND removed IS NOT TRUE
ORDER BY
  log_index;
