-- Profile recipient-level bounded early-outflow metrics for corrected chunk 21.
-- Always dry-run before execution.
--
-- Output grain:
--   One QA and bounded-summary row.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.early_outflow_metrics_chunk_21
--   Intended grain is one validated claim event and recipient per row.
--
-- Join keys and expected cardinality:
--   No JOIN. Candidate keys are the claim event key
--   (claim_transaction_hash, claim_log_index) and the unique claim recipient.
--
-- Filters and time boundaries:
--   No additional filters. The stored metrics use elapsed half-open 24-hour and
--   seven-day windows after block-ordered claim events.
--
-- Row-multiplication risk:
--   None in this query. Grain, monotonicity, nulls, domains, timing consistency,
--   and aggregate reconciliation are measured explicitly.

SELECT
  COUNT(*) AS metric_rows,
  COUNT(DISTINCT CONCAT(
    claim_transaction_hash,
    ':',
    CAST(claim_log_index AS STRING)
  )) AS distinct_claim_event_keys,
  COUNT(DISTINCT claim_recipient) AS distinct_claim_recipients,
  COUNT(*) - COUNT(DISTINCT CONCAT(
    claim_transaction_hash,
    ':',
    CAST(claim_log_index AS STRING)
  )) AS duplicate_rows_above_claim_event_grain,
  COUNTIF(
    claim_timestamp IS NULL
    OR claim_block_number IS NULL
    OR claim_transaction_hash IS NULL
    OR claim_log_index IS NULL
    OR claim_recipient IS NULL
    OR claim_amount_raw IS NULL
    OR positive_outflow_event_count_24h IS NULL
    OR positive_outflow_transaction_count_24h IS NULL
    OR gross_positive_outflow_raw_24h IS NULL
    OR claim_linked_outflow_raw_24h IS NULL
    OR claim_linked_outflow_ratio_24h IS NULL
    OR positive_outflow_event_count_7d IS NULL
    OR positive_outflow_transaction_count_7d IS NULL
    OR gross_positive_outflow_raw_7d IS NULL
    OR claim_linked_outflow_raw_7d IS NULL
    OR claim_linked_outflow_ratio_7d IS NULL
  ) AS critical_null_rows,
  COUNTIF(
    positive_outflow_event_count_24h < 0
    OR positive_outflow_transaction_count_24h < 0
    OR gross_positive_outflow_raw_24h < 0
    OR claim_linked_outflow_raw_24h < 0
    OR positive_outflow_event_count_7d < 0
    OR positive_outflow_transaction_count_7d < 0
    OR gross_positive_outflow_raw_7d < 0
    OR claim_linked_outflow_raw_7d < 0
  ) AS negative_metric_rows,
  COUNTIF(
    positive_outflow_event_count_24h > positive_outflow_event_count_7d
    OR positive_outflow_transaction_count_24h >
      positive_outflow_transaction_count_7d
    OR gross_positive_outflow_raw_24h > gross_positive_outflow_raw_7d
    OR claim_linked_outflow_raw_24h > claim_linked_outflow_raw_7d
  ) AS window_monotonicity_violation_rows,
  COUNTIF(
    claim_linked_outflow_raw_24h > claim_amount_raw
    OR claim_linked_outflow_raw_24h > gross_positive_outflow_raw_24h
    OR claim_linked_outflow_raw_7d > claim_amount_raw
    OR claim_linked_outflow_raw_7d > gross_positive_outflow_raw_7d
    OR claim_linked_outflow_ratio_24h < 0
    OR claim_linked_outflow_ratio_24h > 1
    OR claim_linked_outflow_ratio_7d < 0
    OR claim_linked_outflow_ratio_7d > 1
  ) AS capped_proxy_domain_violation_rows,
  COUNTIF(
    (positive_outflow_event_count_24h = 0 AND (
      first_positive_outflow_timestamp_24h IS NOT NULL
      OR seconds_to_first_positive_outflow_24h IS NOT NULL
    ))
    OR (positive_outflow_event_count_24h > 0 AND (
      first_positive_outflow_timestamp_24h IS NULL
      OR seconds_to_first_positive_outflow_24h < 0
      OR seconds_to_first_positive_outflow_24h >= 86400
    ))
    OR (positive_outflow_event_count_7d = 0 AND (
      first_positive_outflow_timestamp_7d IS NOT NULL
      OR seconds_to_first_positive_outflow_7d IS NOT NULL
    ))
    OR (positive_outflow_event_count_7d > 0 AND (
      first_positive_outflow_timestamp_7d IS NULL
      OR seconds_to_first_positive_outflow_7d < 0
      OR seconds_to_first_positive_outflow_7d >= 604800
    ))
  ) AS first_outflow_consistency_violation_rows,
  COUNTIF(positive_outflow_event_count_24h > 0)
    AS recipients_with_positive_outflow_24h,
  COUNTIF(positive_outflow_event_count_7d > 0)
    AS recipients_with_positive_outflow_7d,
  SUM(positive_outflow_event_count_24h) AS summed_outflow_events_24h,
  SUM(positive_outflow_event_count_7d) AS summed_outflow_events_7d,
  SUM(claim_amount_raw) AS total_claimed_raw,
  SUM(claim_amount_raw) / POW(CAST(10 AS BIGNUMERIC), 18)
    AS total_claimed_arb,
  SUM(gross_positive_outflow_raw_24h) AS gross_positive_outflow_raw_24h,
  SUM(gross_positive_outflow_raw_24h) /
    POW(CAST(10 AS BIGNUMERIC), 18) AS gross_positive_outflow_arb_24h,
  SUM(claim_linked_outflow_raw_24h) AS claim_linked_outflow_raw_24h,
  SUM(claim_linked_outflow_raw_24h) /
    POW(CAST(10 AS BIGNUMERIC), 18) AS claim_linked_outflow_arb_24h,
  SUM(gross_positive_outflow_raw_7d) AS gross_positive_outflow_raw_7d,
  SUM(gross_positive_outflow_raw_7d) /
    POW(CAST(10 AS BIGNUMERIC), 18) AS gross_positive_outflow_arb_7d,
  SUM(claim_linked_outflow_raw_7d) AS claim_linked_outflow_raw_7d,
  SUM(claim_linked_outflow_raw_7d) /
    POW(CAST(10 AS BIGNUMERIC), 18) AS claim_linked_outflow_arb_7d
FROM
  `YOUR_DATASET_ID.early_outflow_metrics_chunk_21`;
