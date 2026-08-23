-- Match one date-bounded late corrected-transfer sample to raw HasClaimed logs.
-- Run each of the three documented date groups as a separate BigQuery job and
-- perform a fresh dry run before every execution.
--
-- Output grain:
--   One row per supplied sample event, including its raw-match count.
--
-- Source tables and source grain:
--   sample_events: SQL literals copied from sql/16 output; one row per sampled
--     corrected Transfer event.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.logs: one row per raw
--     event log.
--
-- Join keys and expected cardinality:
--   LEFT JOIN on transaction_hash, normalized recipient, and amount_raw.
--   Expected cardinality is one sample event to one HasClaimed event.
--
-- Filters:
--   Replace the sample rows and half-open UTC bounds together for each job:
--   A. the two 2023-09-16 samples, bounds 2023-09-16 to 2023-09-17;
--   B. the 2023-09-21 sample, bounds 2023-09-21 to 2023-09-22;
--   C. the two 2023-09-24 samples, bounds 2023-09-24 to 2023-09-25.
--   Raw rows are additionally restricted to the TokenDistributor, HasClaimed
--   topic0, at least two topics, and rows not marked as removed.
--
-- Row-multiplication risk:
--   A malformed source with multiple matching HasClaimed rows could multiply a
--   sample row. The final GROUP BY restores one output row per sample and
--   reports raw_match_rows; analysis readiness requires exactly one match.

WITH sample_events AS (
  -- Active configuration: group A, 2023-09-16.
  SELECT
    'first' AS sample_label,
    TIMESTAMP('2023-09-16 00:16:33+00') AS transfer_timestamp,
    '0x83a3cd3d2cc0ec089694d88ea84c27fbe9bafd4e10142d5db1f87c72ed994ab5'
      AS transaction_hash,
    0 AS transfer_log_index,
    '0xd3974902e1ab1e013087df92567990f14e0950ea' AS recipient,
    CAST('3000000000000000000000' AS BIGNUMERIC) AS amount_raw
  UNION ALL
  SELECT
    'second',
    TIMESTAMP('2023-09-16 00:23:04+00'),
    '0x8b7ec9c0a6fe742f9cac7c923cc46cf6d87f024a9b8a8497cf5f1edf3a26333f',
    0,
    '0x7eb84e42059f0d44269c50f4d3a280fd307a6824',
    CAST('875000000000000000000' AS BIGNUMERIC)
),

raw_claim_parts AS (
  SELECT
    block_timestamp AS raw_claim_timestamp,
    transaction_hash,
    log_index AS raw_claim_log_index,
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
    block_timestamp >= TIMESTAMP('2023-09-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-09-17 00:00:00+00')
    AND address = '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
    AND ARRAY_LENGTH(topics) > 1
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
    CASE
      WHEN amount_high_chunk IS NOT NULL AND amount_low_chunk IS NOT NULL
        THEN CAST(amount_high_chunk AS BIGNUMERIC)
          * CAST(1152921504606846976 AS BIGNUMERIC)
          + CAST(amount_low_chunk AS BIGNUMERIC)
    END AS amount_raw
  FROM
    raw_claim_parts
)

SELECT
  sample.sample_label,
  sample.transfer_timestamp,
  sample.transaction_hash,
  sample.transfer_log_index,
  sample.recipient,
  sample.amount_raw,
  COUNT(raw.transaction_hash) AS raw_match_rows,
  MIN(raw.raw_claim_timestamp) AS raw_claim_timestamp,
  MIN(raw.raw_claim_log_index) AS raw_claim_log_index,
  COUNT(raw.transaction_hash) = 1
    AND MIN(raw.raw_claim_timestamp) = sample.transfer_timestamp
    AS exact_raw_claim_match
FROM
  sample_events AS sample
LEFT JOIN
  raw_claims AS raw
ON
  sample.transaction_hash = raw.transaction_hash
  AND sample.recipient = raw.recipient
  AND sample.amount_raw = raw.amount_raw
GROUP BY
  sample.sample_label,
  sample.transfer_timestamp,
  sample.transaction_hash,
  sample.transfer_log_index,
  sample.recipient,
  sample.amount_raw
ORDER BY
  sample.transfer_timestamp,
  sample.transaction_hash;
