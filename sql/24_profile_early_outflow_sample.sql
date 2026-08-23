-- Profile positive early ARB outflow for one manually validated claim
-- recipient during the first 24 hours after the claim.
--
-- Output grain:
--   One recipient-level QA summary row.
--
-- Source table and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--   One source row represents one decoded event log.
--
-- Candidate source-event key:
--   (transaction_hash, log_index).
--
-- Join keys and expected cardinality:
--   No JOIN. The scalar duplicate-key subquery returns one value.
--
-- Filters and time boundaries:
--   1. Strictly after the sampled claim timestamp
--   2. Through 24 hours after that timestamp, inclusive
--   3. ARB token contract and standard Transfer event
--   4. Sampled claimant as decoded sender
--   5. Self-transfers excluded
--   6. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   None from JOINs. Multiple events are intentionally aggregated to one
--   recipient row. Duplicate event keys are measured before aggregation.
--
-- Metric definitions:
--   gross_positive_outflow_raw sums only amounts greater than zero.
--   capped_claim_linked_outflow_raw is LEAST(gross outflow, claim amount).
--   The cap is a conservative proxy for claim-linked outflow; fungible-token
--   tracing cannot prove which specific ARB units moved.
--
-- Interpretation rule:
--   Outflow is not a demonstrated sale. Destination classification is outside
--   this query and requires separate DEX or reliable address-label evidence.

WITH outgoing_events AS (
  SELECT
    block_number,
    block_timestamp,
    transaction_hash,
    log_index,
    LOWER(JSON_VALUE(args, '$[1]')) AS destination,
    SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC) AS amount_raw
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp > TIMESTAMP('2023-03-23 13:01:22+00')
    AND block_timestamp <= TIMESTAMP('2023-03-24 13:01:22+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND LOWER(JSON_VALUE(args, '$[0]')) =
      '0x27a1b27b2e8bfdd57a3049415dcf6a63ac11667f'
    AND LOWER(JSON_VALUE(args, '$[1]')) !=
      '0x27a1b27b2e8bfdd57a3049415dcf6a63ac11667f'
    AND removed IS NOT TRUE
),

key_counts AS (
  SELECT
    transaction_hash,
    log_index,
    COUNT(*) AS row_count
  FROM
    outgoing_events
  GROUP BY
    transaction_hash,
    log_index
)

SELECT
  COUNT(*) AS candidate_transfer_event_rows,
  COUNTIF(amount_raw = 0) AS zero_value_transfer_event_rows,
  COUNTIF(amount_raw > 0) AS positive_outflow_event_rows,
  COUNT(DISTINCT IF(amount_raw > 0, transaction_hash, NULL))
    AS positive_outflow_transactions,
  (
    SELECT COUNTIF(row_count > 1)
    FROM key_counts
  ) AS duplicated_event_keys,
  COUNTIF(
    transaction_hash IS NULL
    OR log_index IS NULL
    OR block_timestamp IS NULL
  ) AS critical_null_key_rows,
  COUNTIF(
    destination IS NULL
    OR amount_raw IS NULL
    OR amount_raw < 0
  ) AS invalid_or_null_value_rows,
  MIN(IF(amount_raw > 0, block_timestamp, NULL))
    AS first_positive_outflow_timestamp,
  TIMESTAMP_DIFF(
    MIN(IF(amount_raw > 0, block_timestamp, NULL)),
    TIMESTAMP('2023-03-23 13:01:22+00'),
    SECOND
  ) AS seconds_to_first_positive_outflow,
  SUM(IF(amount_raw > 0, amount_raw, CAST(0 AS BIGNUMERIC)))
    AS gross_positive_outflow_raw,
  LEAST(
    SUM(IF(amount_raw > 0, amount_raw, CAST(0 AS BIGNUMERIC))),
    CAST('1625000000000000000000' AS BIGNUMERIC)
  ) AS capped_claim_linked_outflow_raw,
  SAFE_DIVIDE(
    LEAST(
      SUM(IF(amount_raw > 0, amount_raw, CAST(0 AS BIGNUMERIC))),
      CAST('1625000000000000000000' AS BIGNUMERIC)
    ),
    CAST('1625000000000000000000' AS BIGNUMERIC)
  ) AS capped_claim_linked_outflow_ratio
FROM
  outgoing_events;
