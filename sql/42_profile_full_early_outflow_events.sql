-- Profile the full-cohort block-aware early-outflow event layer.
-- Always dry-run before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.early_outflow_events_full_cohort
--   Intended grain is one positive non-self ARB Transfer event per claimant.
--
-- Join keys and expected cardinality:
--   No JOIN. Candidate output key is
--   (outflow_transaction_hash, outflow_log_index).
--
-- Filters and time boundaries:
--   No additional filter. The table is already restricted to the elapsed
--   seven-day half-open window after each block-ordered claim.
--
-- Row-multiplication risk:
--   None in this query. Event-key uniqueness, source cardinality, ordering,
--   windows, amounts, and self-transfer rules are measured explicitly.

SELECT
  COUNT(*) AS matched_outflow_event_rows,
  COUNT(DISTINCT CONCAT(
    outflow_transaction_hash,
    ':',
    CAST(outflow_log_index AS STRING)
  )) AS distinct_outflow_event_keys,
  COUNT(*) - COUNT(DISTINCT CONCAT(
    outflow_transaction_hash,
    ':',
    CAST(outflow_log_index AS STRING)
  )) AS duplicate_rows_above_outflow_event_grain,
  COUNT(DISTINCT outflow_transaction_hash) AS distinct_outflow_transactions,
  COUNT(DISTINCT claim_recipient) AS claim_recipients_with_outflow,
  COUNTIF(
    claim_timestamp IS NULL
    OR claim_block_number IS NULL
    OR claim_transaction_hash IS NULL
    OR claim_log_index IS NULL
    OR claim_recipient IS NULL
    OR claim_amount_raw IS NULL
    OR source_chunk_number IS NULL
    OR outflow_timestamp IS NULL
    OR outflow_block_number IS NULL
    OR outflow_transaction_hash IS NULL
    OR outflow_log_index IS NULL
    OR destination IS NULL
    OR outflow_amount_raw IS NULL
  ) AS critical_null_rows,
  COUNTIF(source_match_rows IS NULL OR source_match_rows != 1)
    AS rows_without_exactly_one_source_match,
  COUNTIF(outflow_amount_raw <= 0) AS nonpositive_amount_rows,
  COUNTIF(destination = claim_recipient) AS self_transfer_rows,
  COUNTIF(
    outflow_block_number < claim_block_number
    OR (
      outflow_block_number = claim_block_number
      AND outflow_log_index <= claim_log_index
    )
  ) AS event_order_violation_rows,
  COUNTIF(outflow_timestamp < claim_timestamp)
    AS before_claim_timestamp_rows,
  COUNTIF(
    outflow_timestamp >= TIMESTAMP_ADD(claim_timestamp, INTERVAL 7 DAY)
  ) AS outside_seven_day_window_rows,
  COUNTIF(outflow_block_number = claim_block_number)
    AS same_block_ordered_outflow_rows,
  MIN(outflow_timestamp) AS first_outflow_timestamp,
  MAX(outflow_timestamp) AS last_outflow_timestamp,
  SUM(outflow_amount_raw) AS gross_outflow_raw,
  SUM(outflow_amount_raw) / POW(CAST(10 AS BIGNUMERIC), 18)
    AS gross_outflow_arb
FROM
  `YOUR_DATASET_ID.early_outflow_events_full_cohort`;
