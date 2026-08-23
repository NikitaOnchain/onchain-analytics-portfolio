-- Profile one partition-bounded interval of decoded ARB transfers sent by the
-- airdrop TokenDistributor. Always dry-run after changing the date bounds.
--
-- Configuration:
--   The executable default is the current approved scan-plan interval. To
--   profile another interval, update both timestamp literals everywhere.
--
-- Purpose:
--   Support a quota-safe, interval-by-interval validation of the transfer-based
--   claim cohort across the full observed claim window.
--
-- Output grain:
--   One QA summary row for the configured interval.
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--   One source row represents one decoded event log.
--
-- Candidate event key:
--   (transaction_hash, log_index).
--
-- Join keys and expected cardinality:
--   No JOIN. Scalar subqueries read grouped QA summaries and each return one
--   value, so they cannot multiply source rows.
--
-- Filters:
--   1. Configured half-open UTC interval
--   2. ARB token contract
--   3. Standard ERC-20 Transfer event signature
--   4. TokenDistributor as the decoded sender
--   5. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. Duplicate source rows are measured at the candidate event
--   key. A transaction can contain multiple event logs.
--
-- JSON decoding:
--   args[0] = sender, args[1] = recipient, args[2] = raw token amount.
--
-- Official references (accessed 2026-08-11):
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema
--   https://arbiscan.io/token/0x912ce59144191c1204e64559fe8253a0e49e6548

WITH decoded_transfers AS (
  SELECT
    block_timestamp,
    transaction_hash,
    log_index,
    LOWER(JSON_VALUE(args, '$[0]')) AS sender,
    LOWER(JSON_VALUE(args, '$[1]')) AS recipient,
    SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC) AS amount_raw
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-09-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-10-01 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
),

claim_transfers AS (
  SELECT
    block_timestamp,
    transaction_hash,
    log_index,
    recipient,
    amount_raw
  FROM
    decoded_transfers
  WHERE
    sender = '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
),

event_key_counts AS (
  SELECT
    transaction_hash,
    log_index,
    COUNT(*) AS row_count
  FROM
    claim_transfers
  GROUP BY
    transaction_hash,
    log_index
),

recipient_counts AS (
  SELECT
    recipient,
    COUNT(*) AS row_count
  FROM
    claim_transfers
  WHERE
    recipient IS NOT NULL
  GROUP BY
    recipient
)

SELECT
  TIMESTAMP('2023-09-16 00:00:00+00') AS period_start,
  TIMESTAMP('2023-10-01 00:00:00+00') AS period_end,
  COUNT(*) AS transfer_event_rows,
  COUNT(DISTINCT transaction_hash) AS distinct_claim_transactions,
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
  ) AS recipients_with_multiple_transfer_events,
  (
    SELECT COALESCE(SUM(IF(row_count > 1, row_count - 1, 0)), 0)
    FROM recipient_counts
  ) AS extra_event_rows_above_one_per_recipient,
  COUNTIF(transaction_hash IS NULL) AS null_transaction_hash_rows,
  COUNTIF(log_index IS NULL) AS null_log_index_rows,
  COUNTIF(block_timestamp IS NULL) AS null_block_timestamp_rows,
  COUNTIF(
    recipient IS NULL
    OR NOT REGEXP_CONTAINS(recipient, r'^0x[0-9a-f]{40}$')
  ) AS invalid_or_null_recipient_rows,
  COUNTIF(amount_raw IS NULL OR amount_raw <= 0) AS invalid_or_null_amount_rows,
  MIN(block_timestamp) AS first_transfer_timestamp,
  MAX(block_timestamp) AS last_transfer_timestamp,
  SUM(amount_raw) AS total_amount_raw,
  SAFE_DIVIDE(
    SUM(amount_raw),
    CAST('1000000000000000000' AS BIGNUMERIC)
  ) AS total_amount_arb
FROM
  claim_transfers;
