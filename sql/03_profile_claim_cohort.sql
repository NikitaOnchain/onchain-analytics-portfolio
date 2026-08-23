-- Profile the complete ARB HasClaimed event cohort before materializing it.
-- Review the BigQuery byte estimate before running this query.
-- WARNING: the 2026-08-11 validation run processed 357.92 GB. Do not rerun
-- the full public-table scan without an explicit quota and storage plan.
-- Do not treat the provisional totals as final analytical metrics until the
-- duplicate, NULL, manual-sample, and independent-reconciliation checks pass.
--
-- Output grain:
--   Exactly one summary row for all matching HasClaimed event logs in the
--   bounded claim-period window.
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.logs
--   One source row represents one event log emitted by a transaction.
--
-- Join keys and expected cardinality:
--   No JOIN. Window functions count matching rows by decoded recipient.
--
-- Filters:
--   1. block_timestamp >= 2023-03-23 00:00:00 UTC
--   2. block_timestamp <  2023-10-01 00:00:00 UTC
--   3. TokenDistributor contract address
--   4. HasClaimed(address,uint256) topic0
--   5. At least two topics so topics[1] can contain the recipient
--
-- The upper timestamp deliberately includes all of September. The query
-- reports the observed maximum claim timestamp, which will later be compared
-- with the deployed contract's claim-period boundary.
--
-- Row-multiplication risk:
--   None from JOINs. Multiple matching logs for one recipient remain visible
--   in the duplicate checks instead of being silently deduplicated.
--
-- Decoding:
--   recipient = final 20 bytes of topics[1]
--   amount     = uint256 in data, recombined as BIGNUMERIC from two chunks
--   ARB units  = raw amount / 10^18
--
-- Official source references (accessed 2026-08-11):
--   https://github.com/ArbitrumFoundation/governance/blob/main/src/TokenDistributor.sol
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema
--
-- Validation run (2026-08-11):
--   583,137 event rows and 583,137 distinct recipients.
--   583,131 distinct transaction hashes; transaction hash is not unique.
--   0 duplicated recipients, critical NULLs, or decoding failures.
--   Observed claim range: 2023-03-23 13:01:22 UTC through
--   2023-09-24 20:12:52 UTC.
--   Provisional claimed amount: 1,092,811,500 ARB.
--   Actual processing and billed volume: 357.92 GB.

WITH raw_claim_logs AS (
  SELECT
    block_timestamp AS claim_timestamp,
    transaction_hash AS claim_transaction_hash,
    topics[SAFE_OFFSET(1)] AS recipient_topic,
    data AS amount_data
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.logs`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-10-01 00:00:00+00')
    AND address = LOWER('0x67a24CE4321aB3aF51c2D0a4801c3E111D88C9d9')
    AND ARRAY_LENGTH(topics) > 1
    AND topics[SAFE_OFFSET(0)] =
      '0x8629b200ebe43db58ad688b85131d53251f3f3be4c14933b4641aeebacf1c08c'
),

decoded_parts AS (
  SELECT
    claim_timestamp,
    claim_transaction_hash,
    CASE
      WHEN REGEXP_CONTAINS(recipient_topic, r'^0x[0-9a-fA-F]{64}$')
        THEN CONCAT('0x', RIGHT(recipient_topic, 40))
    END AS recipient,
    CASE
      WHEN REGEXP_CONTAINS(amount_data, r'^0x[0-9a-fA-F]{64}$')
        THEN SAFE_CAST(
          CONCAT('0x', SUBSTR(RIGHT(amount_data, 30), 1, 15)) AS INT64
        )
    END AS amount_high_chunk,
    CASE
      WHEN REGEXP_CONTAINS(amount_data, r'^0x[0-9a-fA-F]{64}$')
        THEN SAFE_CAST(CONCAT('0x', RIGHT(amount_data, 15)) AS INT64)
    END AS amount_low_chunk
  FROM raw_claim_logs
),

decoded_claims AS (
  SELECT
    claim_timestamp,
    claim_transaction_hash,
    recipient,
    CASE
      WHEN amount_high_chunk IS NOT NULL AND amount_low_chunk IS NOT NULL
        THEN CAST(amount_high_chunk AS BIGNUMERIC)
          * CAST(1152921504606846976 AS BIGNUMERIC)
          + CAST(amount_low_chunk AS BIGNUMERIC)
    END AS amount_raw
  FROM decoded_parts
),

quality_flags AS (
  SELECT
    *,
    COUNT(*) OVER (PARTITION BY recipient) AS recipient_event_rows
  FROM decoded_claims
)

SELECT
  COUNT(*) AS claim_event_rows,
  COUNT(DISTINCT claim_transaction_hash) AS distinct_claim_transactions,
  COUNT(DISTINCT recipient) AS distinct_recipients,
  COUNT(DISTINCT IF(recipient_event_rows > 1, recipient, NULL))
    AS recipients_with_multiple_claim_events,
  COUNTIF(recipient IS NOT NULL) - COUNT(DISTINCT recipient)
    AS extra_event_rows_above_one_per_recipient,
  COUNTIF(claim_transaction_hash IS NULL) AS null_transaction_hash_rows,
  COUNTIF(recipient IS NULL) AS invalid_or_null_recipient_rows,
  COUNTIF(amount_raw IS NULL) AS invalid_or_null_amount_rows,
  MIN(claim_timestamp) AS first_claim_timestamp,
  MAX(claim_timestamp) AS last_claim_timestamp,
  SUM(amount_raw) AS provisional_total_claimed_raw,
  SUM(amount_raw) / CAST(1000000000000000000 AS BIGNUMERIC)
    AS provisional_total_claimed_arb
FROM quality_flags;
