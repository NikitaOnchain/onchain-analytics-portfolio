-- Reconcile the full event layer's chunk-21 subset to the independently
-- materialized bounded chunk-21 event table.
-- Always dry-run before execution.
--
-- Output grain:
--   One reconciliation summary row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.early_outflow_events_full_cohort
--     One qualifying outflow event per row across the full claim cohort.
--   YOUR_DATASET_ID.early_outflow_events_chunk_21
--     One qualifying outflow event per row for the prior bounded validation.
--
-- Join keys and expected cardinality:
--   FULL OUTER JOIN on (outflow_transaction_hash, outflow_log_index), expected
--   one-to-one after both event layers passed event-key uniqueness checks.
--
-- Filters and time boundaries:
--   The full table is restricted to corrected claim chunk 21. Both sides use
--   the same block-aware elapsed seven-day definition.
--
-- Row-multiplication risk:
--   None if the validated keys remain unique. Full-only, bounded-only, and
--   field-mismatch counts expose coverage or transformation drift.

WITH full_subset AS (
  SELECT *
  FROM
    `YOUR_DATASET_ID.early_outflow_events_full_cohort`
  WHERE
    chunk_number = 21
),

comparison AS (
  SELECT
    full_layer.outflow_transaction_hash AS full_transaction_hash,
    full_layer.outflow_log_index AS full_log_index,
    bounded.outflow_transaction_hash AS bounded_transaction_hash,
    bounded.outflow_log_index AS bounded_log_index,
    full_layer.claim_transaction_hash AS full_claim_transaction_hash,
    bounded.claim_transaction_hash AS bounded_claim_transaction_hash,
    full_layer.claim_log_index AS full_claim_log_index,
    bounded.claim_log_index AS bounded_claim_log_index,
    full_layer.claim_recipient AS full_claim_recipient,
    bounded.claim_recipient AS bounded_claim_recipient,
    full_layer.outflow_timestamp AS full_outflow_timestamp,
    bounded.outflow_timestamp AS bounded_outflow_timestamp,
    full_layer.outflow_block_number AS full_outflow_block_number,
    bounded.outflow_block_number AS bounded_outflow_block_number,
    full_layer.destination AS full_destination,
    bounded.destination AS bounded_destination,
    full_layer.outflow_amount_raw AS full_outflow_amount_raw,
    bounded.outflow_amount_raw AS bounded_outflow_amount_raw
  FROM
    full_subset AS full_layer
  FULL OUTER JOIN
    `YOUR_DATASET_ID.early_outflow_events_chunk_21` AS bounded
    USING (outflow_transaction_hash, outflow_log_index)
)

SELECT
  (SELECT COUNT(*) FROM full_subset) AS full_subset_rows,
  (
    SELECT COUNT(*)
    FROM `YOUR_DATASET_ID.early_outflow_events_chunk_21`
  ) AS bounded_rows,
  COUNTIF(bounded_transaction_hash IS NULL) AS full_only_event_rows,
  COUNTIF(full_transaction_hash IS NULL) AS bounded_only_event_rows,
  COUNTIF(
    full_transaction_hash IS NOT NULL
    AND bounded_transaction_hash IS NOT NULL
    AND (
      full_claim_transaction_hash != bounded_claim_transaction_hash
      OR full_claim_log_index != bounded_claim_log_index
      OR full_claim_recipient != bounded_claim_recipient
      OR full_outflow_timestamp != bounded_outflow_timestamp
      OR full_outflow_block_number != bounded_outflow_block_number
      OR full_destination != bounded_destination
      OR full_outflow_amount_raw != bounded_outflow_amount_raw
    )
  ) AS matched_event_field_mismatch_rows,
  COUNTIF(bounded_transaction_hash IS NULL) = 0
    AND COUNTIF(full_transaction_hash IS NULL) = 0
    AND COUNTIF(
      full_transaction_hash IS NOT NULL
      AND bounded_transaction_hash IS NOT NULL
      AND (
        full_claim_transaction_hash != bounded_claim_transaction_hash
        OR full_claim_log_index != bounded_claim_log_index
        OR full_claim_recipient != bounded_claim_recipient
        OR full_outflow_timestamp != bounded_outflow_timestamp
        OR full_outflow_block_number != bounded_outflow_block_number
        OR full_destination != bounded_destination
        OR full_outflow_amount_raw != bounded_outflow_amount_raw
      )
    ) = 0 AS exact_reconciliation
FROM
  comparison;
