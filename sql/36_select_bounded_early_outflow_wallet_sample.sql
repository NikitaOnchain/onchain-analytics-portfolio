-- Select a deterministic five-stratum wallet sample from bounded chunk-21
-- early-outflow metrics and attach the locally materialized outflow events.
-- Always dry-run before execution.
--
-- Output grain:
--   One selected claimant-outflow event pair. A selected zero-outflow claimant
--   has one row with null outflow-event fields. Claim metrics repeat when the
--   sampled claimant has multiple outflow events.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.early_outflow_metrics_chunk_21
--     One validated claim recipient per row.
--   YOUR_DATASET_ID.early_outflow_events_chunk_21
--     One validated positive non-self outflow event per row.
--
-- Join keys and expected cardinality:
--   LEFT JOIN on the exact claim event key
--   (claim_transaction_hash, claim_log_index), expected one-to-many. The join
--   intentionally exposes every stored event for the selected claimants.
--
-- Filters and time boundaries:
--   Metrics and events are already restricted to block-ordered elapsed 24-hour
--   and seven-day windows. Five mutually exclusive QA strata are sampled.
--
-- Row-multiplication risk:
--   Expected for sampled claimants with multiple events. `sample_type` and the
--   outflow event key make the output grain explicit.

WITH sample_candidates AS (
  SELECT
    '01_zero_outflow' AS sample_type,
    metric.*
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_chunk_21` AS metric
  WHERE
    positive_outflow_event_count_7d = 0

  UNION ALL

  SELECT
    '02_after_24h_only' AS sample_type,
    metric.*
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_chunk_21` AS metric
  WHERE
    positive_outflow_event_count_24h = 0
    AND positive_outflow_event_count_7d > 0

  UNION ALL

  SELECT
    '03_single_event_within_24h' AS sample_type,
    metric.*
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_chunk_21` AS metric
  WHERE
    positive_outflow_event_count_24h > 0
    AND positive_outflow_event_count_7d = 1
    AND gross_positive_outflow_raw_7d <= claim_amount_raw

  UNION ALL

  SELECT
    '04_multiple_events_within_7d' AS sample_type,
    metric.*
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_chunk_21` AS metric
  WHERE
    positive_outflow_event_count_24h > 0
    AND positive_outflow_event_count_7d > 1
    AND gross_positive_outflow_raw_7d <= claim_amount_raw

  UNION ALL

  SELECT
    '05_gross_above_claim' AS sample_type,
    metric.*
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_chunk_21` AS metric
  WHERE
    positive_outflow_event_count_24h > 0
    AND gross_positive_outflow_raw_7d > claim_amount_raw
),

selected_claimants AS (
  SELECT * EXCEPT (sample_rank)
  FROM (
    SELECT
      sample_candidates.*,
      ROW_NUMBER() OVER (
        PARTITION BY sample_type
        ORDER BY claim_timestamp, claim_recipient
      ) AS sample_rank
    FROM
      sample_candidates
  )
  WHERE
    sample_rank = 1
)

SELECT
  sample.sample_type,
  sample.claim_recipient,
  sample.claim_timestamp,
  sample.claim_block_number,
  sample.claim_transaction_hash,
  sample.claim_log_index,
  sample.claim_amount_raw /
    POW(CAST(10 AS BIGNUMERIC), 18) AS claim_amount_arb,
  sample.positive_outflow_event_count_24h,
  sample.gross_positive_outflow_raw_24h /
    POW(CAST(10 AS BIGNUMERIC), 18) AS gross_positive_outflow_arb_24h,
  sample.claim_linked_outflow_ratio_24h,
  sample.seconds_to_first_positive_outflow_24h,
  sample.positive_outflow_event_count_7d,
  sample.gross_positive_outflow_raw_7d /
    POW(CAST(10 AS BIGNUMERIC), 18) AS gross_positive_outflow_arb_7d,
  sample.claim_linked_outflow_ratio_7d,
  sample.seconds_to_first_positive_outflow_7d,
  event.outflow_timestamp,
  event.outflow_block_number,
  event.outflow_transaction_hash,
  event.outflow_log_index,
  event.destination,
  event.outflow_amount_raw /
    POW(CAST(10 AS BIGNUMERIC), 18) AS outflow_amount_arb
FROM
  selected_claimants AS sample
LEFT JOIN
  `YOUR_DATASET_ID.early_outflow_events_chunk_21` AS event
  USING (claim_transaction_hash, claim_log_index)
ORDER BY
  sample.sample_type,
  event.outflow_block_number,
  event.outflow_log_index;
