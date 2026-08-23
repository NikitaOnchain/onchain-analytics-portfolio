-- Reconcile claim cohort, event layer, and claim-grain metrics exactly.
-- Always dry-run before execution.
--
-- Output grain:
--   One cross-layer reconciliation summary row.
--
-- Source tables and source grain:
--   corrected_claim_transfers_enriched_chunk_*: one claim per row.
--   early_outflow_events_full_cohort: one qualifying outflow event per row.
--   early_outflow_metrics_full_cohort: one claim and recipient per row.
--
-- Join keys and expected cardinality:
--   No row-level JOIN. Each layer is aggregated independently before scalar
--   comparison, so no row multiplication can affect the reconciliation.
--
-- Filters and time boundaries:
--   Claim wildcard includes final two-digit chunks only. Event 24-hour totals
--   use the same elapsed half-open cutoff as the metric layer; seven-day totals
--   use the already bounded full event table.
--
-- Row-multiplication risk:
--   None. Boolean controls compare exact integer and BIGNUMERIC aggregates.

WITH claim_summary AS (
  SELECT
    COUNT(*) AS claim_rows,
    SUM(amount_raw) AS total_claimed_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

event_summary AS (
  SELECT
    COUNTIF(
      outflow_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR)
    ) AS event_rows_24h,
    SUM(IF(
      outflow_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR),
      outflow_amount_raw,
      CAST(0 AS BIGNUMERIC)
    )) AS gross_outflow_raw_24h,
    COUNT(*) AS event_rows_7d,
    SUM(outflow_amount_raw) AS gross_outflow_raw_7d
  FROM
    `YOUR_DATASET_ID.early_outflow_events_full_cohort`
),

metric_summary AS (
  SELECT
    COUNT(*) AS metric_rows,
    SUM(claim_amount_raw) AS total_claimed_raw,
    SUM(positive_outflow_event_count_24h) AS event_rows_24h,
    SUM(gross_positive_outflow_raw_24h) AS gross_outflow_raw_24h,
    SUM(positive_outflow_event_count_7d) AS event_rows_7d,
    SUM(gross_positive_outflow_raw_7d) AS gross_outflow_raw_7d
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_full_cohort`
)

SELECT
  claim.claim_rows,
  metric.metric_rows,
  claim.total_claimed_raw AS cohort_total_claimed_raw,
  metric.total_claimed_raw AS metric_total_claimed_raw,
  event.event_rows_24h AS event_layer_rows_24h,
  metric.event_rows_24h AS metric_summed_rows_24h,
  event.gross_outflow_raw_24h AS event_layer_gross_raw_24h,
  metric.gross_outflow_raw_24h AS metric_summed_gross_raw_24h,
  event.event_rows_7d AS event_layer_rows_7d,
  metric.event_rows_7d AS metric_summed_rows_7d,
  event.gross_outflow_raw_7d AS event_layer_gross_raw_7d,
  metric.gross_outflow_raw_7d AS metric_summed_gross_raw_7d,
  claim.claim_rows = metric.metric_rows AS claim_row_count_match,
  claim.total_claimed_raw = metric.total_claimed_raw
    AS claimed_amount_match,
  event.event_rows_24h = metric.event_rows_24h
    AS event_count_24h_match,
  event.gross_outflow_raw_24h = metric.gross_outflow_raw_24h
    AS gross_amount_24h_match,
  event.event_rows_7d = metric.event_rows_7d
    AS event_count_7d_match,
  event.gross_outflow_raw_7d = metric.gross_outflow_raw_7d
    AS gross_amount_7d_match
FROM
  claim_summary AS claim
CROSS JOIN
  event_summary AS event
CROSS JOIN
  metric_summary AS metric;
