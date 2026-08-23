-- Validate decoded_events coverage for the ARB TokenDistributor.
-- Review the BigQuery byte estimate before running this query.
--
-- Purpose:
--   Confirm whether Google provides decoded HasClaimed rows and whether the
--   JSON args contain usable recipient and amount values before materializing
--   the full claimer cohort from this source.
--
-- Output grain:
--   One decoded event row. The candidate event key is
--   (transaction_hash, log_index), not transaction_hash alone.
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
--   2. TokenDistributor address
--   3. Rows that are not marked as removed
--
-- The first pass intentionally does not filter event_hash. It inspects the
-- event_hash, event_signature, and args formats emitted for this contract.
--
-- Row-multiplication risk:
--   None from JOINs. Multiple events can share a transaction hash and remain
--   distinct through log_index.
--
-- Official source (accessed 2026-08-11):
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema

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
  AND address = LOWER('0x67a24CE4321aB3aF51c2D0a4801c3E111D88C9d9')
  AND removed IS NOT TRUE
ORDER BY
  block_timestamp,
  transaction_hash,
  log_index
LIMIT 10;
