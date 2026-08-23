-- Match the deterministic middle late-window sample to raw HasClaimed.
--
-- Output grain: one row for one supplied corrected Transfer event.
-- Sources: one SQL-literal sample event and event-grain public raw logs.
-- JOIN: LEFT JOIN on transaction hash, normalized recipient, and raw amount;
-- expected one-to-one. `raw_match_rows` exposes unexpected multiplication.
-- Filters: 2023-09-21 UTC, TokenDistributor, HasClaimed topic0, valid indexed
-- recipient topic, and rows not marked as removed.

WITH sample_event AS (
  SELECT
    'middle' AS sample_label,
    TIMESTAMP('2023-09-21 18:13:15+00') AS transfer_timestamp,
    '0x5aed9cca5f9db30124de7a12823b13caf8aea6168c27d82cdd7c2393224d348c'
      AS transaction_hash,
    1 AS transfer_log_index,
    '0x9f9a1937cfdfedbe1bee0fbba18d29538a9b28fa' AS recipient,
    CAST('3250000000000000000000' AS BIGNUMERIC) AS amount_raw
),
raw_claim_parts AS (
  SELECT
    block_timestamp AS raw_claim_timestamp,
    transaction_hash,
    log_index AS raw_claim_log_index,
    LOWER(CONCAT('0x', RIGHT(topics[SAFE_OFFSET(1)], 40))) AS recipient,
    SAFE_CAST(
      CONCAT('0x', SUBSTR(RIGHT(data, 30), 1, 15)) AS INT64
    ) AS amount_high_chunk,
    SAFE_CAST(CONCAT('0x', RIGHT(data, 15)) AS INT64) AS amount_low_chunk
  FROM `bigquery-public-data.goog_blockchain_arbitrum_one_us.logs`
  WHERE
    block_timestamp >= TIMESTAMP('2023-09-21 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-09-22 00:00:00+00')
    AND address = '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
    AND ARRAY_LENGTH(topics) > 1
    AND REGEXP_CONTAINS(topics[SAFE_OFFSET(1)], r'^0x[0-9a-fA-F]{64}$')
    AND REGEXP_CONTAINS(data, r'^0x[0-9a-fA-F]{64}$')
    AND topics[SAFE_OFFSET(0)] =
      '0x8629b200ebe43db58ad688b85131d53251f3f3be4c14933b4641aeebacf1c08c'
    AND removed IS NOT TRUE
),
raw_claims AS (
  SELECT
    raw_claim_timestamp,
    transaction_hash,
    raw_claim_log_index,
    recipient,
    CAST(amount_high_chunk AS BIGNUMERIC)
      * CAST(1152921504606846976 AS BIGNUMERIC)
      + CAST(amount_low_chunk AS BIGNUMERIC) AS amount_raw
  FROM raw_claim_parts
)
SELECT
  sample.*,
  COUNT(raw.transaction_hash) AS raw_match_rows,
  MIN(raw.raw_claim_timestamp) AS raw_claim_timestamp,
  MIN(raw.raw_claim_log_index) AS raw_claim_log_index,
  COUNT(raw.transaction_hash) = 1
    AND MIN(raw.raw_claim_timestamp) = sample.transfer_timestamp
    AS exact_raw_claim_match
FROM sample_event AS sample
LEFT JOIN raw_claims AS raw
  ON sample.transaction_hash = raw.transaction_hash
  AND sample.recipient = raw.recipient
  AND sample.amount_raw = raw.amount_raw
GROUP BY
  sample.sample_label,
  sample.transfer_timestamp,
  sample.transaction_hash,
  sample.transfer_log_index,
  sample.recipient,
  sample.amount_raw;
