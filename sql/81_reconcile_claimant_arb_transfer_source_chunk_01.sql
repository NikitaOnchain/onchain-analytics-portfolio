-- Reconcile transfer-source chunk 01 to a fresh bounded public-source rebuild.
-- Fresh-dry-run this exact statement before execution.
--
-- Output grain:
--   Exactly one QA summary row for source chunk 01.
--
-- Source tables and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One decoded event log per source row, pre-aggregated here to
--     (transaction_hash, log_index).
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per final two-digit row;
--     reduced to a DISTINCT claimant set.
--   YOUR_DATASET_ID.retention_arb_transfer_source_chunk_01
--     Intended grain: one claimant-related positive ARB Transfer event per
--     (transaction_hash, log_index).
--
-- Join keys and expected cardinality:
--   FULL OUTER JOIN on (transaction_hash, log_index), expected one-to-one after
--   both event sources are pre-aggregated to the candidate key. Source-side
--   duplicate counts remain explicit.
--
-- Filters and time boundaries:
--   Fresh public rebuild uses [2023-03-16, 2023-03-23) UTC, the verified ARB
--   token address, Transfer(address,address,uint256), rows not marked removed,
--   positive amount, and at least one endpoint in the validated claimant set.
--
-- Row-multiplication risk:
--   Claimant membership uses EXISTS semijoins. Both compared datasets collapse
--   to one row per event key before the FULL OUTER JOIN, so an unexpected source
--   duplicate is reported rather than multiplying reconciliation rows.

WITH claimants AS (
  SELECT DISTINCT
    LOWER(recipient) AS recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

public_source AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[0]'))) AS sender,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[1]'))) AS destination,
    ANY_VALUE(SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC)) AS amount_raw,
    COUNT(*) AS source_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-16 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-23 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
  GROUP BY
    transaction_hash,
    log_index
),

expected_events AS (
  SELECT
    source.*
  FROM
    public_source AS source
  WHERE
    source.amount_raw > 0
    AND (
      EXISTS (
        SELECT 1
        FROM claimants
        WHERE recipient = source.sender
      )
      OR EXISTS (
        SELECT 1
        FROM claimants
        WHERE recipient = source.destination
      )
    )
),

materialized_events AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(source_chunk_number) AS source_chunk_number,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(sender) AS sender,
    ANY_VALUE(destination) AS destination,
    ANY_VALUE(amount_raw) AS amount_raw,
    ANY_VALUE(source_match_rows) AS source_match_rows,
    COUNT(*) AS materialized_match_rows
  FROM
    `YOUR_DATASET_ID.retention_arb_transfer_source_chunk_01`
  GROUP BY
    transaction_hash,
    log_index
),

reconciled AS (
  SELECT
    COALESCE(expected.transaction_hash, materialized.transaction_hash)
      AS transaction_hash,
    COALESCE(expected.log_index, materialized.log_index) AS log_index,
    expected.transaction_hash IS NOT NULL AS has_expected_event,
    materialized.transaction_hash IS NOT NULL AS has_materialized_event,
    expected.block_timestamp AS expected_block_timestamp,
    materialized.block_timestamp AS materialized_block_timestamp,
    expected.block_number AS expected_block_number,
    materialized.block_number AS materialized_block_number,
    expected.transaction_index AS expected_transaction_index,
    materialized.transaction_index AS materialized_transaction_index,
    expected.sender AS expected_sender,
    materialized.sender AS materialized_sender,
    expected.destination AS expected_destination,
    materialized.destination AS materialized_destination,
    expected.amount_raw AS expected_amount_raw,
    materialized.amount_raw AS materialized_amount_raw,
    expected.source_match_rows AS expected_source_match_rows,
    materialized.source_match_rows AS materialized_source_match_rows,
    materialized.source_chunk_number,
    materialized.materialized_match_rows
  FROM
    expected_events AS expected
  FULL OUTER JOIN
    materialized_events AS materialized
    USING (transaction_hash, log_index)
)

SELECT
  (SELECT COUNT(*) FROM expected_events) AS expected_event_rows,
  (SELECT COUNT(*) FROM materialized_events) AS materialized_event_rows,
  COUNT(*) AS reconciled_event_keys,
  COUNTIF(has_expected_event AND NOT has_materialized_event)
    AS missing_materialized_event_rows,
  COUNTIF(NOT has_expected_event AND has_materialized_event)
    AS unexpected_materialized_event_rows,
  COUNTIF(expected_source_match_rows != 1) AS expected_source_match_defect_rows,
  COUNTIF(materialized_source_match_rows != 1)
    AS materialized_source_match_defect_rows,
  COUNTIF(materialized_match_rows != 1) AS materialized_key_defect_rows,
  COUNTIF(source_chunk_number != 1) AS source_chunk_number_mismatch_rows,
  COUNTIF(
    has_expected_event
    AND has_materialized_event
    AND expected_block_timestamp != materialized_block_timestamp
  ) AS timestamp_mismatch_rows,
  COUNTIF(
    has_expected_event
    AND has_materialized_event
    AND expected_block_number != materialized_block_number
  ) AS block_number_mismatch_rows,
  COUNTIF(
    has_expected_event
    AND has_materialized_event
    AND expected_transaction_index != materialized_transaction_index
  ) AS transaction_index_mismatch_rows,
  COUNTIF(
    has_expected_event
    AND has_materialized_event
    AND expected_sender != materialized_sender
  ) AS sender_mismatch_rows,
  COUNTIF(
    has_expected_event
    AND has_materialized_event
    AND expected_destination != materialized_destination
  ) AS destination_mismatch_rows,
  COUNTIF(
    has_expected_event
    AND has_materialized_event
    AND expected_amount_raw != materialized_amount_raw
  ) AS amount_mismatch_rows,
  (SELECT SUM(amount_raw) FROM expected_events) AS expected_amount_raw,
  (SELECT SUM(amount_raw) FROM materialized_events) AS materialized_amount_raw
FROM
  reconciled;
