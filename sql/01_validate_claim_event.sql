-- Validate the ARB airdrop HasClaimed event against raw Arbitrum logs.
-- Review the BigQuery byte estimate before running this query.
--
-- Output grain:
--   One matching raw log row. This is not yet a deduplicated claimer cohort.
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.logs
--   One source row represents one event log emitted by a transaction.
--
-- Join keys:
--   None. This validation query reads one table and performs no JOIN.
--
-- Filters:
--   Arbitrum TokenDistributor address, HasClaimed topic0, and the first UTC
--   calendar day of the public claim period.
--
-- Row-multiplication risk:
--   None from JOINs. A transaction can contain multiple logs, so
--   transaction_hash must not be assumed to be a unique log key.
--
-- Expected encoding:
--   topics[0] = Keccak-256("HasClaimed(address,uint256)")
--   topics[1] = indexed recipient address, padded to 32 bytes
--   data      = unindexed uint256 amount
--
-- Validation run (2026-08-11):
--   10 rows returned; 3.71 GB processed and billed.
--   The contract address and event topic matched the expected values, and the
--   displayed recipient topics and raw amount data were populated.
--   This query does not count all claims because ORDER BY ... LIMIT 10 returns
--   only a display sample.
--
-- Official sources (accessed 2026-08-11):
--   https://forum.arbitrum.foundation/t/aip-7-arbitrum-one-governance-parameter-fixes/15920
--   https://github.com/ArbitrumFoundation/governance/blob/main/src/TokenDistributor.sol
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema

SELECT
  block_timestamp,
  transaction_hash,
  address,
  topics[SAFE_OFFSET(0)] AS event_topic0,
  topics[SAFE_OFFSET(1)] AS recipient_topic,
  data
FROM
  `bigquery-public-data.goog_blockchain_arbitrum_one_us.logs`
WHERE
  block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
  AND block_timestamp < TIMESTAMP('2023-03-24 00:00:00+00')
  AND address = LOWER('0x67a24CE4321aB3aF51c2D0a4801c3E111D88C9d9')
  AND ARRAY_LENGTH(topics) > 1
  AND topics[SAFE_OFFSET(0)] = '0x8629b200ebe43db58ad688b85131d53251f3f3be4c14933b4641aeebacf1c08c'
ORDER BY
  block_timestamp
LIMIT 10;
