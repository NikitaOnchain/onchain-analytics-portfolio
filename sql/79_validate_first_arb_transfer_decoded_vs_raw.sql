-- Validate the first observed decoded ARB Transfer against its raw event log.
-- Fresh-dry-run this exact statement before execution.
--
-- Output grain:
--   Exactly one QA summary row for the supplied event key.
--
-- Source tables and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One decoded event log per source row.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.logs
--     One raw event log per source row.
--
-- Join keys and expected cardinality:
--   FULL OUTER JOIN on (transaction_hash, log_index), expected one-to-one
--   after each source is pre-aggregated to that event key. Match counts remain
--   visible and must both equal one.
--
-- Filters and time boundaries:
--   Both public sources use the half-open UTC day [2023-03-16, 2023-03-17),
--   the verified ARB token address, transaction hash, and log index 19. The
--   decoded source additionally requires Transfer(address,address,uint256).
--   Rows marked removed are excluded.
--
-- Row-multiplication risk:
--   None after source pre-aggregation. Duplicate source rows are counted in
--   decoded_match_rows and raw_match_rows rather than multiplied by the join.
--
-- Decoding:
--   Raw topics[1] and topics[2] contain the indexed sender and destination.
--   The exact event amount fits within the final 30 hexadecimal digits and is
--   reconstructed from two 15-digit chunks before comparison with decoded
--   args[2]. This exact-event technique is not a general uint256 decoder.

WITH decoded_source AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(event_hash) AS event_hash,
    ANY_VALUE(event_signature) AS event_signature,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[0]'))) AS sender,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[1]'))) AS destination,
    ANY_VALUE(SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC)) AS amount_raw,
    COUNT(*) AS decoded_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-17 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND transaction_hash =
      '0x9cdbb4672b549c26d97cac29f9cd73c1951656e0622ba4b9ed0abff2ee58698d'
    AND log_index = 19
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
  GROUP BY
    transaction_hash,
    log_index
),

raw_parts AS (
  SELECT
    transaction_hash,
    log_index,
    block_timestamp,
    block_number,
    transaction_index,
    topics[SAFE_OFFSET(0)] AS event_topic0,
    CASE
      WHEN REGEXP_CONTAINS(topics[SAFE_OFFSET(1)], r'^0x[0-9a-fA-F]{64}$')
        THEN LOWER(CONCAT('0x', RIGHT(topics[SAFE_OFFSET(1)], 40)))
    END AS sender,
    CASE
      WHEN REGEXP_CONTAINS(topics[SAFE_OFFSET(2)], r'^0x[0-9a-fA-F]{64}$')
        THEN LOWER(CONCAT('0x', RIGHT(topics[SAFE_OFFSET(2)], 40)))
    END AS destination,
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
    block_timestamp >= TIMESTAMP('2023-03-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-17 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND transaction_hash =
      '0x9cdbb4672b549c26d97cac29f9cd73c1951656e0622ba4b9ed0abff2ee58698d'
    AND log_index = 19
    AND ARRAY_LENGTH(topics) >= 3
    AND removed IS NOT TRUE
),

raw_source AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(event_topic0) AS event_topic0,
    ANY_VALUE(sender) AS sender,
    ANY_VALUE(destination) AS destination,
    ANY_VALUE(
      CAST(amount_high_chunk AS BIGNUMERIC)
        * CAST(1152921504606846976 AS BIGNUMERIC)
        + CAST(amount_low_chunk AS BIGNUMERIC)
    ) AS amount_raw,
    COUNT(*) AS raw_match_rows
  FROM
    raw_parts
  GROUP BY
    transaction_hash,
    log_index
),

joined AS (
  SELECT
    COALESCE(decoded.transaction_hash, raw.transaction_hash) AS transaction_hash,
    COALESCE(decoded.log_index, raw.log_index) AS log_index,
    decoded.block_timestamp AS decoded_block_timestamp,
    raw.block_timestamp AS raw_block_timestamp,
    decoded.block_number AS decoded_block_number,
    raw.block_number AS raw_block_number,
    decoded.transaction_index AS decoded_transaction_index,
    raw.transaction_index AS raw_transaction_index,
    decoded.event_hash AS decoded_event_hash,
    raw.event_topic0 AS raw_event_topic0,
    decoded.event_signature AS decoded_event_signature,
    decoded.sender AS decoded_sender,
    raw.sender AS raw_sender,
    decoded.destination AS decoded_destination,
    raw.destination AS raw_destination,
    decoded.amount_raw AS decoded_amount_raw,
    raw.amount_raw AS raw_amount_raw,
    decoded.decoded_match_rows,
    raw.raw_match_rows
  FROM
    decoded_source AS decoded
  FULL OUTER JOIN
    raw_source AS raw
    USING (transaction_hash, log_index)
)

SELECT
  COUNT(*) AS joined_event_rows,
  COUNTIF(decoded_match_rows != 1 OR decoded_match_rows IS NULL)
    AS decoded_match_defect_rows,
  COUNTIF(raw_match_rows != 1 OR raw_match_rows IS NULL)
    AS raw_match_defect_rows,
  COUNTIF(
    decoded_block_timestamp IS NULL
    OR raw_block_timestamp IS NULL
    OR decoded_block_number IS NULL
    OR raw_block_number IS NULL
    OR decoded_transaction_index IS NULL
    OR raw_transaction_index IS NULL
    OR decoded_event_hash IS NULL
    OR raw_event_topic0 IS NULL
    OR decoded_sender IS NULL
    OR raw_sender IS NULL
    OR decoded_destination IS NULL
    OR raw_destination IS NULL
    OR decoded_amount_raw IS NULL
    OR raw_amount_raw IS NULL
  ) AS critical_null_rows,
  COUNTIF(decoded_block_timestamp != raw_block_timestamp)
    AS timestamp_mismatch_rows,
  COUNTIF(decoded_block_number != raw_block_number)
    AS block_number_mismatch_rows,
  COUNTIF(decoded_transaction_index != raw_transaction_index)
    AS transaction_index_mismatch_rows,
  COUNTIF(decoded_event_hash != raw_event_topic0)
    AS event_topic_mismatch_rows,
  COUNTIF(decoded_sender != raw_sender) AS sender_mismatch_rows,
  COUNTIF(decoded_destination != raw_destination)
    AS destination_mismatch_rows,
  COUNTIF(decoded_amount_raw != raw_amount_raw)
    AS amount_mismatch_rows,
  ARRAY_AGG(
    STRUCT(
      transaction_hash,
      log_index,
      decoded_block_timestamp AS block_timestamp,
      decoded_block_number AS block_number,
      decoded_transaction_index AS transaction_index,
      decoded_event_hash,
      raw_event_topic0,
      decoded_event_signature,
      decoded_sender,
      raw_sender,
      decoded_destination,
      raw_destination,
      decoded_amount_raw,
      raw_amount_raw,
      decoded_match_rows,
      raw_match_rows
    )
    LIMIT 1
  )[SAFE_OFFSET(0)] AS validated_event
FROM
  joined;
