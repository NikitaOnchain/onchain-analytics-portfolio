-- Profile signed claimant ARB Transfer legs and reconcile them to the complete
-- event source, validated claims, and compact exact claim-order batches.
-- Always fresh-dry-run this exact read-only statement before execution.
--
-- Output grain:
--   Exactly one QA summary row.
--
-- Source tables and source grain:
--   retention_arb_claimant_transfer_legs: one claimant endpoint role per event.
--   retention_arb_transfer_source_chunk_01..29: one ARB Transfer event per key.
--   corrected_claim_transfers_enriched_chunk_01..21: one claim and recipient.
--   post_claim_transaction_order_batch_*: one claim transaction per hash.
--
-- Join keys and expected cardinality:
--   Event source to leg profile uses (transaction_hash, log_index), one-to-one
--   after leg roles are aggregated. Claims to compact order are many-to-one by
--   transaction hash. Claims to destination legs are one-to-one by exact claim
--   event key and recipient. All potentially non-unique inputs are aggregated
--   before a reconciliation JOIN, preventing hidden row multiplication.
--
-- Filters and time boundaries:
--   Final numeric transfer chunks 01..29 and claim chunks 01..21 only. Compact
--   order suffixes are frozen to 01_20, 21, 22 and 23.
--
-- Row-multiplication risk:
--   The materialized layer intentionally has one or two legs per source event.
--   This query checks the exact role count, unique leg key, self-transfer
--   netting, source-field agreement, and one claim destination leg per claim.

WITH claimants AS (
  SELECT DISTINCT
    LOWER(recipient) AS claimant_address
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
    AND SAFE_CAST(_TABLE_SUFFIX AS INT64) BETWEEN 1 AND 21
),

claims AS (
  SELECT
    block_timestamp AS claim_timestamp,
    block_number AS claim_block_number,
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    LOWER(recipient) AS claim_recipient,
    amount_raw AS claim_amount_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
    AND SAFE_CAST(_TABLE_SUFFIX AS INT64) BETWEEN 1 AND 21
),

order_keys AS (
  SELECT
    claim_receipt_timestamp,
    claim_receipt_block_number,
    claim_transaction_hash,
    claim_transaction_index,
    claim_receipt_match_rows,
    claim_block_match_rows
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_order_batch_*`
  WHERE
    _TABLE_SUFFIX IN ('01_20', '21', '22', '23')
),

order_key_profile AS (
  SELECT
    claim_transaction_hash,
    ANY_VALUE(claim_receipt_timestamp) AS claim_receipt_timestamp,
    ANY_VALUE(claim_receipt_block_number) AS claim_receipt_block_number,
    ANY_VALUE(claim_transaction_index) AS claim_transaction_index,
    ANY_VALUE(claim_receipt_match_rows) AS claim_receipt_match_rows,
    ANY_VALUE(claim_block_match_rows) AS claim_block_match_rows,
    COUNT(*) AS order_match_rows
  FROM
    order_keys
  GROUP BY
    claim_transaction_hash
),

legs AS (
  SELECT *
  FROM
    `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs`
),

leg_summary AS (
  SELECT
    COUNT(*) AS leg_rows,
    COUNT(DISTINCT claimant_address) AS distinct_leg_claimants,
    COUNTIF(leg_role = 'sender') AS sender_leg_rows,
    COUNTIF(leg_role = 'destination') AS destination_leg_rows,
    COUNTIF(is_self_transfer) AS self_transfer_leg_rows,
    SUM(IF(is_self_transfer, signed_amount_raw, 0))
      AS self_transfer_net_signed_amount_raw,
    SUM(signed_amount_raw) AS all_leg_net_signed_amount_raw,
    SUM(amount_raw) AS all_leg_gross_amount_raw,
    COUNTIF(
      source_chunk_number IS NULL
      OR block_timestamp IS NULL
      OR block_number IS NULL
      OR transaction_hash IS NULL
      OR transaction_index IS NULL
      OR log_index IS NULL
      OR claimant_address IS NULL
      OR leg_role IS NULL
      OR counterparty_address IS NULL
      OR amount_raw IS NULL
      OR signed_amount_raw IS NULL
      OR is_self_transfer IS NULL
      OR source_match_rows IS NULL
    ) AS critical_null_leg_rows,
    COUNTIF(leg_role NOT IN ('sender', 'destination')) AS invalid_leg_role_rows,
    COUNTIF(
      NOT REGEXP_CONTAINS(claimant_address, r'^0x[0-9a-f]{40}$')
      OR NOT REGEXP_CONTAINS(counterparty_address, r'^0x[0-9a-f]{40}$')
    ) AS invalid_leg_address_rows,
    COUNTIF(amount_raw <= 0) AS non_positive_leg_amount_rows,
    COUNTIF(
      (leg_role = 'sender' AND signed_amount_raw != -amount_raw)
      OR (leg_role = 'destination' AND signed_amount_raw != amount_raw)
    ) AS invalid_signed_amount_rows,
    COUNTIF(
      is_self_transfer != (claimant_address = counterparty_address)
    ) AS self_transfer_flag_mismatch_rows,
    COUNTIF(source_match_rows != 1) AS invalid_source_match_leg_rows
  FROM
    legs
),

leg_key_profile AS (
  SELECT
    transaction_hash,
    log_index,
    leg_role,
    COUNT(*) AS leg_key_rows
  FROM
    legs
  GROUP BY
    transaction_hash,
    log_index,
    leg_role
),

leg_key_summary AS (
  SELECT
    COUNT(*) AS distinct_leg_keys,
    COUNTIF(leg_key_rows > 1) AS duplicated_leg_keys,
    SUM(IF(leg_key_rows > 1, leg_key_rows, 0)) AS rows_on_duplicate_leg_keys,
    SUM(leg_key_rows - 1) AS extra_rows_above_leg_grain
  FROM
    leg_key_profile
),

leg_event_profile AS (
  SELECT
    transaction_hash,
    log_index,
    COUNT(*) AS leg_rows_on_event,
    COUNTIF(leg_role = 'sender') AS sender_legs_on_event,
    COUNTIF(leg_role = 'destination') AS destination_legs_on_event,
    LOGICAL_OR(is_self_transfer) AS is_self_transfer_event,
    SUM(signed_amount_raw) AS event_net_signed_amount_raw
  FROM
    legs
  GROUP BY
    transaction_hash,
    log_index
),

leg_event_summary AS (
  SELECT
    COUNT(*) AS distinct_leg_event_keys,
    COUNTIF(leg_rows_on_event NOT IN (1, 2)) AS invalid_leg_multiplicity_events,
    COUNTIF(sender_legs_on_event > 1 OR destination_legs_on_event > 1)
      AS duplicate_role_events,
    COUNTIF(leg_rows_on_event = 2) AS two_leg_events,
    COUNTIF(is_self_transfer_event) AS self_transfer_events,
    COUNTIF(
      is_self_transfer_event
      AND (
        leg_rows_on_event != 2
        OR sender_legs_on_event != 1
        OR destination_legs_on_event != 1
        OR event_net_signed_amount_raw != 0
      )
    ) AS invalid_self_transfer_net_events
  FROM
    leg_event_profile
),

source AS (
  SELECT
    source_chunk_number,
    block_timestamp,
    block_number,
    transaction_hash,
    transaction_index,
    log_index,
    sender,
    destination,
    amount_raw,
    source_match_rows,
    EXISTS (
      SELECT 1 FROM claimants
      WHERE claimant_address = sender
    ) AS sender_is_claimant,
    EXISTS (
      SELECT 1 FROM claimants
      WHERE claimant_address = destination
    ) AS destination_is_claimant
  FROM
    `YOUR_DATASET_ID.retention_arb_transfer_source_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
    AND SAFE_CAST(_TABLE_SUFFIX AS INT64) BETWEEN 1 AND 29
),

source_to_leg AS (
  SELECT
    source.transaction_hash,
    source.log_index,
    source.sender_is_claimant,
    source.destination_is_claimant,
    COUNTIF(leg.leg_role = 'sender') AS actual_sender_legs,
    COUNTIF(leg.leg_role = 'destination') AS actual_destination_legs,
    COUNTIF(
      leg.transaction_hash IS NOT NULL
      AND (
        leg.source_chunk_number != source.source_chunk_number
        OR leg.block_timestamp != source.block_timestamp
        OR leg.block_number != source.block_number
        OR leg.transaction_index != source.transaction_index
        OR leg.amount_raw != source.amount_raw
        OR leg.source_match_rows != source.source_match_rows
        OR (
          leg.leg_role = 'sender'
          AND (
            leg.claimant_address != source.sender
            OR leg.counterparty_address != source.destination
          )
        )
        OR (
          leg.leg_role = 'destination'
          AND (
            leg.claimant_address != source.destination
            OR leg.counterparty_address != source.sender
          )
        )
      )
    ) AS source_field_mismatch_leg_rows
  FROM
    source
  LEFT JOIN
    legs AS leg
    USING (transaction_hash, log_index)
  GROUP BY
    source.transaction_hash,
    source.log_index,
    source.sender_is_claimant,
    source.destination_is_claimant
),

source_to_leg_summary AS (
  SELECT
    COUNT(*) AS reconciled_source_events,
    COUNTIF(
      actual_sender_legs != IF(sender_is_claimant, 1, 0)
      OR actual_destination_legs != IF(destination_is_claimant, 1, 0)
    ) AS source_events_with_leg_role_mismatch,
    SUM(source_field_mismatch_leg_rows) AS source_field_mismatch_leg_rows
  FROM
    source_to_leg
),

claim_destination_leg_profile AS (
  SELECT
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    claimant_address AS claim_recipient,
    ANY_VALUE(block_timestamp) AS leg_block_timestamp,
    ANY_VALUE(block_number) AS leg_block_number,
    ANY_VALUE(transaction_index) AS leg_transaction_index,
    ANY_VALUE(amount_raw) AS leg_amount_raw,
    ANY_VALUE(signed_amount_raw) AS leg_signed_amount_raw,
    COUNT(*) AS claim_destination_leg_rows
  FROM
    legs
  WHERE
    leg_role = 'destination'
  GROUP BY
    claim_transaction_hash,
    claim_log_index,
    claim_recipient
),

claim_reconciliation AS (
  SELECT
    claim.*,
    order_key.claim_receipt_timestamp,
    order_key.claim_receipt_block_number,
    order_key.claim_transaction_index,
    order_key.claim_receipt_match_rows,
    order_key.claim_block_match_rows,
    order_key.order_match_rows,
    claim_leg.leg_block_timestamp,
    claim_leg.leg_block_number,
    claim_leg.leg_transaction_index,
    claim_leg.leg_amount_raw,
    claim_leg.leg_signed_amount_raw,
    claim_leg.claim_destination_leg_rows
  FROM
    claims AS claim
  LEFT JOIN
    order_key_profile AS order_key
    USING (claim_transaction_hash)
  LEFT JOIN
    claim_destination_leg_profile AS claim_leg
    USING (claim_transaction_hash, claim_log_index, claim_recipient)
),

claim_summary AS (
  SELECT
    COUNT(*) AS claim_rows,
    COUNT(DISTINCT claim_recipient) AS distinct_claim_recipients,
    COUNT(DISTINCT FORMAT(
      '%s#%d', claim_transaction_hash, claim_log_index
    )) AS distinct_claim_event_keys,
    COUNTIF(order_match_rows IS NULL) AS claims_missing_order_key,
    COUNTIF(order_match_rows != 1) AS claims_with_duplicate_order_keys,
    COUNTIF(claim_destination_leg_rows IS NULL)
      AS claims_missing_destination_leg,
    COUNTIF(claim_destination_leg_rows != 1)
      AS claims_with_duplicate_destination_legs,
    COUNTIF(
      leg_amount_raw != claim_amount_raw
      OR leg_signed_amount_raw != claim_amount_raw
    ) AS claim_amount_leg_mismatch_rows,
    COUNTIF(
      claim_receipt_timestamp != claim_timestamp
      OR claim_receipt_block_number != claim_block_number
      OR leg_block_timestamp != claim_timestamp
      OR leg_block_number != claim_block_number
      OR leg_transaction_index != claim_transaction_index
    ) AS claim_order_metadata_mismatch_rows,
    COUNTIF(
      claim_receipt_match_rows != 1
      OR claim_block_match_rows != 1
    ) AS claims_without_exact_order_source_match
  FROM
    claim_reconciliation
),

order_summary AS (
  SELECT
    COUNT(*) AS order_rows,
    COUNT(DISTINCT claim_transaction_hash) AS distinct_order_transaction_hashes,
    COUNT(*) - COUNT(DISTINCT claim_transaction_hash)
      AS duplicate_order_transaction_hash_rows,
    COUNTIF(
      claim_receipt_timestamp IS NULL
      OR claim_receipt_block_number IS NULL
      OR claim_transaction_hash IS NULL
      OR claim_transaction_index IS NULL
      OR claim_receipt_match_rows IS NULL
      OR claim_block_match_rows IS NULL
    ) AS critical_null_order_rows
  FROM
    order_keys
)

SELECT
  leg_metrics.*,
  leg_keys.*,
  leg_events.*,
  source_reconciliation.*,
  claim_metrics.*,
  order_metrics.*
FROM
  leg_summary AS leg_metrics
CROSS JOIN
  leg_key_summary AS leg_keys
CROSS JOIN
  leg_event_summary AS leg_events
CROSS JOIN
  source_to_leg_summary AS source_reconciliation
CROSS JOIN
  claim_summary AS claim_metrics
CROSS JOIN
  order_summary AS order_metrics;
