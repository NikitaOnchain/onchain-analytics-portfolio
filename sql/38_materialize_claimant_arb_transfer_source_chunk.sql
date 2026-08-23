-- Materialize one non-overlapping interval of claimant-originated ARB Transfers.
-- Always update the target chunk number and both UTC bounds together, then
-- dry-run the exact statement immediately before execution.
--
-- Configuration in this saved example:
--   Source chunk 01, half-open interval 2023-03-23 through 2023-03-27 UTC.
--
-- Analytical meaning:
--   Rows are positive non-self ARB transfers from validated claim recipients.
--   They are candidate early-outflow events, not evidence of token sales.
--
-- Output grain:
--   One decoded ARB Transfer event per row, identified by
--   (transaction_hash, log_index).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row. Only final
--     two-digit chunk tables are included.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One decoded event log per row.
--
-- Join keys and expected cardinality:
--   source.sender = claimant.recipient, expected many-to-one. The claimant CTE
--   uses DISTINCT as an additional cardinality guard. The decoded source is
--   pre-aggregated to one row per event key and retains source_match_rows.
--
-- Filters and time boundaries:
--   1. Half-open UTC interval [2023-03-23, 2023-03-27)
--   2. ARB token Transfer events that are not marked removed
--   3. Sender belongs to the validated claim cohort
--   4. Positive amount and destination different from sender
--
-- Row-multiplication risk:
--   Public duplicate rows are collapsed at the event key before the join.
--   DISTINCT prevents duplicate claimant rows from multiplying source events.
--   The follow-up profile checks both event-key uniqueness and source_match_rows.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.claimant_arb_transfer_source_chunk_01`
CLUSTER BY
  sender
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary positive non-self ARB Transfers from validated claim recipients, source chunk 01.'
)
AS
WITH claimants AS (
  SELECT DISTINCT
    recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

source_events AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[0]'))) AS sender,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[1]'))) AS destination,
    ANY_VALUE(
      SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC)
    ) AS amount_raw,
    COUNT(*) AS source_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-27 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
  GROUP BY
    transaction_hash,
    log_index
)

SELECT
  1 AS source_chunk_number,
  source.block_timestamp,
  source.block_number,
  source.transaction_hash,
  source.log_index,
  source.sender,
  source.destination,
  source.amount_raw,
  source.source_match_rows
FROM
  source_events AS source
INNER JOIN
  claimants AS claimant
  ON source.sender = claimant.recipient
WHERE
  source.amount_raw > 0
  AND source.destination != source.sender;
