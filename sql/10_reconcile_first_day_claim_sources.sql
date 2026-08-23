-- Reconcile first-day raw HasClaimed events with decoded ARB transfers at the
-- row level. Always dry-run this query before execution.
--
-- Purpose:
--   Test whether both sources contain the same claim transaction, recipient,
--   and raw amount tuples on 2023-03-23 UTC.
--
-- Output grain:
--   One reconciliation summary row for 2023-03-23 UTC.
--
-- Source tables and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.logs
--     One source row represents one raw event log.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One source row represents one decoded event log.
--
-- Comparison grain:
--   One distinct (transaction_hash, recipient, amount_raw) tuple.
--   log_index is intentionally excluded because HasClaimed and Transfer are
--   different logs within the same transaction and have different indexes.
--
-- Join keys and expected cardinality:
--   No JOIN. EXCEPT DISTINCT compares normalized sets in both directions.
--   Scalar subqueries each return one value and cannot multiply rows.
--
-- Filters shared by both sources:
--   1. 2023-03-23 00:00:00 UTC inclusive to 2023-03-24 00:00:00 UTC exclusive
--   2. Rows that are not marked as removed
--
-- Raw-only filters:
--   TokenDistributor address, HasClaimed topic0, and at least two topics.
--
-- Decoded-only filters:
--   ARB token address, standard Transfer signature, and TokenDistributor as
--   the decoded sender.
--
-- Row-multiplication risk:
--   None from JOINs. EXCEPT DISTINCT deliberately removes duplicate tuples.
--   Row counts and distinct tuple counts are both reported so an unexpected
--   duplicate cannot be hidden by the set operation.
--
-- Official references (accessed 2026-08-11):
--   https://github.com/ArbitrumFoundation/governance/blob/main/src/TokenDistributor.sol
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema

WITH raw_claim_parts AS (
  SELECT
    transaction_hash,
    CASE
      WHEN REGEXP_CONTAINS(
        topics[SAFE_OFFSET(1)],
        r'^0x[0-9a-fA-F]{64}$'
      )
        THEN LOWER(CONCAT('0x', RIGHT(topics[SAFE_OFFSET(1)], 40)))
    END AS recipient,
    CASE
      WHEN REGEXP_CONTAINS(data, r'^0x[0-9a-fA-F]{64}$')
        THEN SAFE_CAST(
          CONCAT('0x', SUBSTR(RIGHT(data, 30), 1, 15)) AS INT64
        )
    END AS amount_high_chunk,
    CASE
      WHEN REGEXP_CONTAINS(data, r'^0x[0-9a-fA-F]{64}$')
        THEN SAFE_CAST(CONCAT('0x', RIGHT(data, 15)) AS INT64)
    END AS amount_low_chunk
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.logs`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-24 00:00:00+00')
    AND address = '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
    AND ARRAY_LENGTH(topics) > 1
    AND topics[SAFE_OFFSET(0)] =
      '0x8629b200ebe43db58ad688b85131d53251f3f3be4c14933b4641aeebacf1c08c'
    AND removed IS NOT TRUE
),

raw_claims AS (
  SELECT
    transaction_hash,
    recipient,
    CASE
      WHEN amount_high_chunk IS NOT NULL AND amount_low_chunk IS NOT NULL
        THEN CAST(amount_high_chunk AS BIGNUMERIC)
          * CAST(1152921504606846976 AS BIGNUMERIC)
          + CAST(amount_low_chunk AS BIGNUMERIC)
    END AS amount_raw
  FROM
    raw_claim_parts
),

decoded_transfer_parts AS (
  SELECT
    transaction_hash,
    LOWER(JSON_VALUE(args, '$[0]')) AS sender,
    LOWER(JSON_VALUE(args, '$[1]')) AS recipient,
    SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC) AS amount_raw
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-24 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
),

claim_transfers AS (
  SELECT
    transaction_hash,
    recipient,
    amount_raw
  FROM
    decoded_transfer_parts
  WHERE
    sender = '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
),

distinct_raw_claims AS (
  SELECT DISTINCT
    transaction_hash,
    recipient,
    amount_raw
  FROM
    raw_claims
),

distinct_claim_transfers AS (
  SELECT DISTINCT
    transaction_hash,
    recipient,
    amount_raw
  FROM
    claim_transfers
),

raw_only AS (
  SELECT
    transaction_hash,
    recipient,
    amount_raw
  FROM
    distinct_raw_claims
  EXCEPT DISTINCT
  SELECT
    transaction_hash,
    recipient,
    amount_raw
  FROM
    distinct_claim_transfers
),

transfer_only AS (
  SELECT
    transaction_hash,
    recipient,
    amount_raw
  FROM
    distinct_claim_transfers
  EXCEPT DISTINCT
  SELECT
    transaction_hash,
    recipient,
    amount_raw
  FROM
    distinct_raw_claims
)

SELECT
  (SELECT COUNT(*) FROM raw_claims) AS raw_claim_rows,
  (SELECT COUNT(*) FROM distinct_raw_claims) AS distinct_raw_tuples,
  (SELECT COUNT(*) FROM claim_transfers) AS decoded_transfer_rows,
  (SELECT COUNT(*) FROM distinct_claim_transfers)
    AS distinct_decoded_transfer_tuples,
  (SELECT COUNT(*) FROM raw_only) AS raw_only_tuples,
  (SELECT COUNT(*) FROM transfer_only) AS transfer_only_tuples,
  (SELECT COUNT(*) FROM raw_claims)
    - (SELECT COUNT(*) FROM distinct_raw_claims) AS duplicate_raw_tuples,
  (SELECT COUNT(*) FROM claim_transfers)
    - (SELECT COUNT(*) FROM distinct_claim_transfers)
    AS duplicate_decoded_transfer_tuples,
  (SELECT COUNT(*) FROM raw_only) = 0
    AND (SELECT COUNT(*) FROM transfer_only) = 0
    AS exact_set_match;
