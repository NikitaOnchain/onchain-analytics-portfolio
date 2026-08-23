-- Probe positive decoded ARB Transfers in [2023-03-08, 2023-03-16) UTC.
-- Fresh-dry-run the exact statement before execution.
--
-- Output grain: exactly one summary row for the bounded interval.
-- Source: Arbitrum decoded_events, one decoded event log per source row.
-- Joins: none. Source rows collapse to (transaction_hash, log_index).
-- Row-multiplication risk: none; source_match_rows exposes duplicates.

WITH events AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(
      SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC)
    ) AS amount_raw,
    COUNT(*) AS source_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-08 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-16 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
  GROUP BY
    transaction_hash,
    log_index
)

SELECT
  COUNTIF(amount_raw > 0) AS positive_transfer_rows,
  COUNTIF(amount_raw > 0 AND source_match_rows != 1)
    AS non_unique_positive_transfer_rows,
  COUNTIF(amount_raw IS NULL) AS invalid_or_null_amount_rows,
  ARRAY_AGG(
    IF(
      amount_raw > 0,
      STRUCT(
        block_timestamp,
        block_number,
        transaction_hash,
        transaction_index,
        log_index,
        source_match_rows,
        amount_raw
      ),
      NULL
    )
    IGNORE NULLS
    ORDER BY block_number, transaction_index, log_index, transaction_hash
    LIMIT 1
  )[SAFE_OFFSET(0)] AS first_positive_transfer
FROM
  events;
