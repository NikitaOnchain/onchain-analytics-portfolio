-- Inspect the first observed activity time for each active member of the
-- deterministic full-cohort wallet sample against independent public receipt
-- and transaction tables. Always dry-run the exact statement before execution.
--
-- Analytical meaning:
--   A matching row is a successful top-level transaction initiated by the
--   sampled claim recipient at the stored first-activity timestamp. It is
--   address activity, not proof of retained human usage, protocol engagement,
--   token retention, or sales.
--
-- Output grain:
--   One sampled active claim event. Candidate transaction details are retained
--   in an array because several transactions from one sender can share a block
--   timestamp.
--
-- Source tables and source grain:
--   Inline sampled claims: one exact claim event per active QA stratum.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.receipts
--     Intended grain is one receipt per transaction hash.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.transactions
--     Intended grain is one top-level transaction per transaction hash.
--
-- Join keys and expected cardinality:
--   Sample recipient plus exact first-activity timestamp to receipt is
--   intentionally one-to-many when several transactions share a timestamp.
--   Receipt transaction hash to public transaction hash is expected one-to-one
--   after both public sources are pre-aggregated with match counts.
--
-- Filters and time boundaries:
--   Public scans are restricted to [2023-03-23, 2023-03-24) and
--   [2023-03-29, 2023-03-30) UTC, the two dates containing the three stored
--   first-activity timestamps. Only successful receipts from sampled senders
--   are eligible, and the exact claim transaction is excluded.
--
-- Row-multiplication risk:
--   Public sources are pre-aggregated to transaction hash. Candidate rows are
--   aggregated to sampled claim grain before output.

WITH sampled AS (
  SELECT
    *
  FROM
    UNNEST([
      STRUCT(
        'Activity after 24h only' AS sample_stratum,
        TIMESTAMP('2023-03-25 10:10:08+00') AS claim_timestamp,
        '0x00009ef3322a7a8f43914f4e4c097d48d1e93dbb919d821e71a00cc22674fb65'
          AS claim_transaction_hash,
        0 AS claim_log_index,
        '0x7bdd87782feac3d36c55293ebe73193be9e64948'
          AS claim_recipient,
        TIMESTAMP('2023-03-29 19:09:45+00')
          AS stored_first_activity_timestamp_7d
      ),
      STRUCT(
        'Multiple transactions within 7d' AS sample_stratum,
        TIMESTAMP('2023-03-23 14:23:31+00') AS claim_timestamp,
        '0x00000d09613b6fb968165313725bafbfdaa570111d993d2a805ec26680c9e52c'
          AS claim_transaction_hash,
        16 AS claim_log_index,
        '0x129827c20cdb26b7e6b475c48505a933a857e839'
          AS claim_recipient,
        TIMESTAMP('2023-03-23 14:25:03+00')
          AS stored_first_activity_timestamp_7d
      ),
      STRUCT(
        'One transaction within 7d' AS sample_stratum,
        TIMESTAMP('2023-03-23 13:55:45+00') AS claim_timestamp,
        '0x00002e601e2befe3df720d83a5288137bd222ab16bce0ed16bac21d49b0315bd'
          AS claim_transaction_hash,
        76 AS claim_log_index,
        '0xbf2bf114fd009a11e367bea9af7de88c8bcac138'
          AS claim_recipient,
        TIMESTAMP('2023-03-23 13:55:56+00')
          AS stored_first_activity_timestamp_7d
      )
    ])
),

receipt_source AS (
  SELECT
    transaction_hash,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_hash) AS block_hash,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(LOWER(from_address)) AS from_address,
    ANY_VALUE(LOWER(to_address)) AS to_address,
    ANY_VALUE(LOWER(contract_address)) AS contract_address,
    ANY_VALUE(gas_used) AS gas_used,
    ANY_VALUE(status) AS status,
    COUNT(*) AS receipt_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.receipts`
  WHERE
    (
      block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
      AND block_timestamp < TIMESTAMP('2023-03-24 00:00:00+00')
    )
    OR (
      block_timestamp >= TIMESTAMP('2023-03-29 00:00:00+00')
      AND block_timestamp < TIMESTAMP('2023-03-30 00:00:00+00')
    )
  GROUP BY
    transaction_hash
),

transaction_source AS (
  SELECT
    transaction_hash,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_hash) AS block_hash,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(LOWER(from_address)) AS from_address,
    ANY_VALUE(LOWER(to_address)) AS to_address,
    COUNT(*) AS transaction_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.transactions`
  WHERE
    (
      block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
      AND block_timestamp < TIMESTAMP('2023-03-24 00:00:00+00')
    )
    OR (
      block_timestamp >= TIMESTAMP('2023-03-29 00:00:00+00')
      AND block_timestamp < TIMESTAMP('2023-03-30 00:00:00+00')
    )
  GROUP BY
    transaction_hash
),

candidates AS (
  SELECT
    sample.*,
    receipt.transaction_hash AS activity_transaction_hash,
    receipt.block_timestamp AS activity_timestamp,
    receipt.block_hash AS activity_block_hash,
    receipt.transaction_index AS activity_transaction_index,
    receipt.from_address AS activity_from_address,
    receipt.to_address AS activity_to_address,
    receipt.contract_address AS created_contract_address,
    receipt.gas_used AS activity_gas_used,
    receipt.status AS receipt_status,
    receipt.receipt_match_rows,
    transaction.transaction_match_rows,
    receipt.block_timestamp != transaction.block_timestamp
      AS transaction_timestamp_mismatch,
    receipt.block_hash != transaction.block_hash
      AS transaction_block_hash_mismatch,
    receipt.transaction_index != transaction.transaction_index
      AS transaction_index_mismatch,
    receipt.from_address != transaction.from_address
      AS transaction_sender_mismatch,
    receipt.to_address IS DISTINCT FROM transaction.to_address
      AS transaction_target_mismatch
  FROM
    sampled AS sample
  LEFT JOIN
    receipt_source AS receipt
    ON receipt.from_address = sample.claim_recipient
    AND receipt.block_timestamp = sample.stored_first_activity_timestamp_7d
    AND receipt.transaction_hash != sample.claim_transaction_hash
    AND receipt.status = 1
  LEFT JOIN
    transaction_source AS transaction
    USING (transaction_hash)
),

reconciled AS (
  SELECT
    sample_stratum,
    claim_timestamp,
    claim_transaction_hash,
    claim_log_index,
    claim_recipient,
    stored_first_activity_timestamp_7d,
    COUNTIF(activity_transaction_hash IS NOT NULL)
      AS candidate_activity_transaction_rows,
    COUNTIF(receipt_match_rows != 1) AS non_unique_receipt_candidate_rows,
    COUNTIF(transaction_match_rows IS NULL OR transaction_match_rows != 1)
      AS rows_without_one_transaction_match,
    COUNTIF(
      transaction_timestamp_mismatch
      OR transaction_block_hash_mismatch
      OR transaction_index_mismatch
      OR transaction_sender_mismatch
      OR transaction_target_mismatch
    ) AS receipt_transaction_mismatch_rows,
    stored_first_activity_timestamp_7d < claim_timestamp
      OR stored_first_activity_timestamp_7d
        >= TIMESTAMP_ADD(claim_timestamp, INTERVAL 7 DAY)
      AS stored_first_activity_window_violation,
    ARRAY_AGG(
      IF(
        activity_transaction_hash IS NOT NULL,
        STRUCT(
          activity_timestamp,
          activity_block_hash,
          activity_transaction_hash,
          activity_transaction_index,
          activity_from_address,
          activity_to_address,
          created_contract_address,
          activity_gas_used,
          receipt_status,
          CONCAT(
            'https://arbiscan.io/tx/',
            activity_transaction_hash
          ) AS activity_arbiscan_url
        ),
        NULL
      )
      IGNORE NULLS
      ORDER BY activity_transaction_index
    ) AS candidate_activity_transactions
  FROM
    candidates
  GROUP BY
    sample_stratum,
    claim_timestamp,
    claim_transaction_hash,
    claim_log_index,
    claim_recipient,
    stored_first_activity_timestamp_7d
)

SELECT
  *
FROM
  reconciled
ORDER BY
  sample_stratum;
