-- Profile ARB Transfer events received by the airdrop TokenDistributor during
-- one partition-bounded interval. Update both timestamp literals together and
-- always dry-run before execution.
--
-- Purpose:
--   Measure positive ARB inflows returned to the TokenDistributor for the
--   balance-equation reconciliation of the claimed aggregate.
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
--   No JOIN. The scalar duplicate-key subquery returns one value.
--
-- Filters:
--   1. Configured half-open UTC interval
--   2. ARB token contract
--   3. Standard ERC-20 Transfer event signature
--   4. TokenDistributor as the decoded recipient
--   5. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. Duplicate source rows are measured at the candidate event
--   key. The positive-return count and amount exclude zero-value transfers.
--
-- JSON decoding:
--   args[0] = sender, args[1] = recipient, args[2] = raw token amount.

WITH inbound AS (
  SELECT
    block_timestamp,
    transaction_hash,
    log_index,
    LOWER(JSON_VALUE(args, '$[0]')) AS sender,
    SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC) AS amount_raw
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 13:01:22+00')
    AND block_timestamp < TIMESTAMP('2023-03-27 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND LOWER(JSON_VALUE(args, '$[1]')) =
      '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
    AND removed IS NOT TRUE
),

key_counts AS (
  SELECT
    transaction_hash,
    log_index,
    COUNT(*) AS row_count
  FROM
    inbound
  GROUP BY
    transaction_hash,
    log_index
)

SELECT
  TIMESTAMP('2023-03-23 13:01:22+00') AS interval_start,
  TIMESTAMP('2023-03-27 00:00:00+00') AS interval_end,
  COUNT(*) AS inbound_event_rows,
  COUNTIF(amount_raw > 0) AS positive_inbound_event_rows,
  COUNT(DISTINCT IF(amount_raw > 0, transaction_hash, NULL))
    AS positive_inbound_transactions,
  COUNT(DISTINCT IF(amount_raw > 0, sender, NULL))
    AS positive_inbound_senders,
  (
    SELECT COUNTIF(row_count > 1)
    FROM key_counts
  ) AS duplicated_event_keys,
  COUNTIF(
    transaction_hash IS NULL
    OR log_index IS NULL
    OR block_timestamp IS NULL
  ) AS critical_null_key_rows,
  COUNTIF(sender IS NULL) AS null_sender_rows,
  COUNTIF(amount_raw IS NULL OR amount_raw < 0)
    AS invalid_or_null_amount_rows,
  MIN(IF(amount_raw > 0, block_timestamp, NULL))
    AS first_positive_inbound_timestamp,
  MAX(IF(amount_raw > 0, block_timestamp, NULL))
    AS last_positive_inbound_timestamp,
  SUM(IF(amount_raw > 0, amount_raw, CAST(0 AS BIGNUMERIC)))
    AS positive_inbound_raw,
  SAFE_DIVIDE(
    SUM(IF(amount_raw > 0, amount_raw, CAST(0 AS BIGNUMERIC))),
    CAST('1000000000000000000' AS BIGNUMERIC)
  ) AS positive_inbound_arb
FROM
  inbound;
