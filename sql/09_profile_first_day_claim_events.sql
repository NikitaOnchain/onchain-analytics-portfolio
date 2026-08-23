-- Profile raw HasClaimed events on the first UTC claim day for reconciliation
-- with decoded ARB transfers. Always dry-run this query before execution.
--
-- Purpose:
--   Build an identically bounded raw-event profile that can be compared with
--   sql/08_profile_first_day_claim_transfers.sql.
--
-- Output grain:
--   One QA summary row for 2023-03-23 UTC.
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.logs
--   One source row represents one event log.
--
-- Candidate event key:
--   (transaction_hash, log_index).
--
-- Join keys and expected cardinality:
--   No JOIN. Scalar subqueries read grouped QA summaries and each return one
--   value, so they cannot multiply source rows.
--
-- Filters:
--   1. 2023-03-23 00:00:00 UTC inclusive to 2023-03-24 00:00:00 UTC exclusive
--   2. TokenDistributor contract address
--   3. HasClaimed(address,uint256) topic0
--   4. At least two topics so topics[1] can contain the recipient
--   5. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. Duplicate source rows are measured at the candidate event
--   key. A transaction may legitimately contain multiple event logs.
--
-- Decoding:
--   recipient = final 20 bytes of topics[1]
--   amount     = uint256 in data, recombined as BIGNUMERIC from two chunks
--   ARB units  = raw amount / 10^18
--
-- Official references (accessed 2026-08-11):
--   https://github.com/ArbitrumFoundation/governance/blob/main/src/TokenDistributor.sol
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema

WITH raw_claim_logs AS (
  SELECT
    block_timestamp AS claim_timestamp,
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    topics[SAFE_OFFSET(1)] AS recipient_topic,
    data AS amount_data
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

decoded_parts AS (
  SELECT
    claim_timestamp,
    claim_transaction_hash,
    claim_log_index,
    CASE
      WHEN REGEXP_CONTAINS(recipient_topic, r'^0x[0-9a-fA-F]{64}$')
        THEN LOWER(CONCAT('0x', RIGHT(recipient_topic, 40)))
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
  FROM
    raw_claim_logs
),

decoded_claims AS (
  SELECT
    claim_timestamp,
    claim_transaction_hash,
    claim_log_index,
    recipient,
    CASE
      WHEN amount_high_chunk IS NOT NULL AND amount_low_chunk IS NOT NULL
        THEN CAST(amount_high_chunk AS BIGNUMERIC)
          * CAST(1152921504606846976 AS BIGNUMERIC)
          + CAST(amount_low_chunk AS BIGNUMERIC)
    END AS amount_raw
  FROM
    decoded_parts
),

event_key_counts AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNT(*) AS row_count
  FROM
    decoded_claims
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

recipient_counts AS (
  SELECT
    recipient,
    COUNT(*) AS row_count
  FROM
    decoded_claims
  WHERE
    recipient IS NOT NULL
  GROUP BY
    recipient
)

SELECT
  COUNT(*) AS claim_event_rows,
  COUNT(DISTINCT claim_transaction_hash) AS distinct_claim_transactions,
  COUNT(DISTINCT recipient) AS distinct_recipients,
  (
    SELECT COUNTIF(row_count > 1)
    FROM event_key_counts
  ) AS duplicated_event_keys,
  (
    SELECT COALESCE(SUM(IF(row_count > 1, row_count - 1, 0)), 0)
    FROM event_key_counts
  ) AS extra_rows_above_event_grain,
  (
    SELECT COUNTIF(row_count > 1)
    FROM recipient_counts
  ) AS recipients_with_multiple_claim_events,
  (
    SELECT COALESCE(SUM(IF(row_count > 1, row_count - 1, 0)), 0)
    FROM recipient_counts
  ) AS extra_event_rows_above_one_per_recipient,
  COUNTIF(claim_transaction_hash IS NULL) AS null_transaction_hash_rows,
  COUNTIF(claim_log_index IS NULL) AS null_log_index_rows,
  COUNTIF(claim_timestamp IS NULL) AS null_block_timestamp_rows,
  COUNTIF(
    recipient IS NULL
    OR NOT REGEXP_CONTAINS(recipient, r'^0x[0-9a-f]{40}$')
  ) AS invalid_or_null_recipient_rows,
  COUNTIF(amount_raw IS NULL OR amount_raw <= 0) AS invalid_or_null_amount_rows,
  MIN(claim_timestamp) AS first_claim_timestamp,
  MAX(claim_timestamp) AS last_claim_timestamp,
  SUM(amount_raw) AS total_claimed_raw,
  SAFE_DIVIDE(
    SUM(amount_raw),
    CAST('1000000000000000000' AS BIGNUMERIC)
  ) AS total_claimed_arb
FROM
  decoded_claims;
