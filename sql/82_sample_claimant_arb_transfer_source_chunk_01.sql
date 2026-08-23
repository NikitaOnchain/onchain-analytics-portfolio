-- Select a deterministic five-event wallet sample from transfer source chunk 01.
-- Fresh-dry-run this exact statement before execution.
--
-- Output grain:
--   One sampled ARB Transfer event per (transaction_hash, log_index), expected
--   five rows: first/middle/last claimant outbound and first/last claimant
--   inbound events by exact event order.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.retention_arb_transfer_source_chunk_01
--     One claimant-related positive ARB Transfer event per event key.
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per final two-digit row;
--     defensively aggregated to one row per normalized recipient.
--
-- Join keys and expected cardinality:
--   sampled.claim_recipient = claims.claim_recipient, expected many sampled
--   events to one claim. claim_match_rows must equal one for every output row.
--   Claimant membership uses EXISTS semijoins and cannot multiply events.
--
-- Filters and time boundaries:
--   Reads only materialized source chunk 01, already bounded to
--   [2023-03-16, 2023-03-23) UTC. Selection is deterministic under
--   (block_timestamp, block_number, transaction_index, log_index,
--   transaction_hash).
--
-- Row-multiplication risk:
--   The claim table is aggregated to recipient before the LEFT JOIN. Duplicate
--   claim matches remain visible through claim_match_rows. Sample positions are
--   mutually exclusive for the observed 13 outbound and three inbound events.

WITH claims AS (
  SELECT
    LOWER(recipient) AS claim_recipient,
    ANY_VALUE(block_timestamp) AS claim_timestamp,
    ANY_VALUE(block_number) AS claim_block_number,
    ANY_VALUE(transaction_hash) AS claim_transaction_hash,
    ANY_VALUE(log_index) AS claim_log_index,
    ANY_VALUE(amount_raw) AS claim_amount_raw,
    COUNT(*) AS claim_match_rows
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
  GROUP BY
    claim_recipient
),

annotated AS (
  SELECT
    source.*,
    EXISTS (
      SELECT 1
      FROM claims
      WHERE claim_recipient = source.sender
    ) AS sender_is_claimant,
    EXISTS (
      SELECT 1
      FROM claims
      WHERE claim_recipient = source.destination
    ) AS destination_is_claimant
  FROM
    `YOUR_DATASET_ID.retention_arb_transfer_source_chunk_01` AS source
),

directed AS (
  SELECT
    annotated.*,
    CASE
      WHEN sender_is_claimant AND NOT destination_is_claimant
        THEN 'claimant_outbound'
      WHEN NOT sender_is_claimant AND destination_is_claimant
        THEN 'claimant_inbound'
      WHEN sender_is_claimant AND destination_is_claimant
        THEN 'claimant_to_claimant'
      ELSE 'invalid_non_claimant'
    END AS sample_direction,
    CASE
      WHEN sender_is_claimant THEN sender
      WHEN destination_is_claimant THEN destination
    END AS claim_recipient,
    CASE
      WHEN sender_is_claimant THEN destination
      WHEN destination_is_claimant THEN sender
    END AS counterparty
  FROM
    annotated
),

ranked AS (
  SELECT
    directed.*,
    COUNT(*) OVER (PARTITION BY sample_direction) AS direction_event_count,
    ROW_NUMBER() OVER (
      PARTITION BY sample_direction
      ORDER BY
        block_timestamp,
        block_number,
        transaction_index,
        log_index,
        transaction_hash
    ) AS direction_order_ascending,
    ROW_NUMBER() OVER (
      PARTITION BY sample_direction
      ORDER BY
        block_timestamp DESC,
        block_number DESC,
        transaction_index DESC,
        log_index DESC,
        transaction_hash DESC
    ) AS direction_order_descending
  FROM
    directed
),

sampled AS (
  SELECT
    CASE
      WHEN sample_direction = 'claimant_outbound'
        AND direction_order_ascending = 1
        THEN 'outbound_first'
      WHEN sample_direction = 'claimant_outbound'
        AND direction_order_ascending = CAST(CEIL(direction_event_count / 2.0) AS INT64)
        THEN 'outbound_middle'
      WHEN sample_direction = 'claimant_outbound'
        AND direction_order_descending = 1
        THEN 'outbound_last'
      WHEN sample_direction = 'claimant_inbound'
        AND direction_order_ascending = 1
        THEN 'inbound_first'
      WHEN sample_direction = 'claimant_inbound'
        AND direction_order_descending = 1
        THEN 'inbound_last'
    END AS sample_label,
    ranked.*
  FROM
    ranked
  WHERE
    (
      sample_direction = 'claimant_outbound'
      AND (
        direction_order_ascending = 1
        OR direction_order_ascending = CAST(CEIL(direction_event_count / 2.0) AS INT64)
        OR direction_order_descending = 1
      )
    )
    OR (
      sample_direction = 'claimant_inbound'
      AND (
        direction_order_ascending = 1
        OR direction_order_descending = 1
      )
    )
)

SELECT
  sampled.sample_label,
  sampled.sample_direction,
  sampled.direction_event_count,
  sampled.direction_order_ascending,
  sampled.block_timestamp AS transfer_timestamp,
  sampled.block_number AS transfer_block_number,
  sampled.transaction_hash AS transfer_transaction_hash,
  sampled.transaction_index AS transfer_transaction_index,
  sampled.log_index AS transfer_log_index,
  sampled.sender,
  sampled.destination,
  sampled.claim_recipient,
  sampled.counterparty,
  sampled.amount_raw AS transfer_amount_raw,
  sampled.amount_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS transfer_amount_arb,
  claims.claim_timestamp,
  claims.claim_block_number,
  claims.claim_transaction_hash,
  claims.claim_log_index,
  claims.claim_amount_raw,
  claims.claim_amount_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS claim_amount_arb,
  claims.claim_match_rows,
  sampled.block_timestamp < claims.claim_timestamp AS precedes_claim_by_timestamp,
  TIMESTAMP_DIFF(claims.claim_timestamp, sampled.block_timestamp, SECOND)
    AS seconds_before_claim,
  CONCAT('https://arbiscan.io/tx/', sampled.transaction_hash, '#eventlog')
    AS transfer_explorer_url,
  CONCAT('https://arbiscan.io/address/', sampled.claim_recipient)
    AS claimant_explorer_url
FROM
  sampled
LEFT JOIN
  claims
  USING (claim_recipient)
ORDER BY
  sample_label;
