-- Reconcile compact chart dimensions to the validated claim-grain table.
-- Always dry-run immediately before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.early_outflow_metrics_full_cohort
--   One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   No row-level JOIN. CROSS JOINs attach one-row global totals to aggregate
--   summaries and therefore do not multiply claim rows.
--
-- Filters and time boundaries:
--   No claim rows are filtered. Timing labels cover the stored elapsed,
--   half-open seven-day window plus the no-outflow state.
--
-- Row-multiplication risk:
--   None at claim grain. The checks explicitly reconcile all segment and
--   timing counts and amount totals back to the single source table.

WITH metrics AS (
  SELECT
    claim_amount_raw,
    claim_amount_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS claim_amount_arb,
    positive_outflow_event_count_24h,
    claim_linked_outflow_raw_24h,
    positive_outflow_event_count_7d,
    claim_linked_outflow_raw_7d,
    seconds_to_first_positive_outflow_7d
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_full_cohort`
),

global_totals AS (
  SELECT
    COUNT(*) AS claim_rows,
    SUM(claim_amount_raw) AS claimed_raw,
    SUM(claim_linked_outflow_raw_24h) AS claim_linked_outflow_raw_24h,
    SUM(claim_linked_outflow_raw_7d) AS claim_linked_outflow_raw_7d
  FROM
    metrics
),

segment_labeled AS (
  SELECT
    CASE
      WHEN claim_amount_arb <= 875 THEN 1
      WHEN claim_amount_arb <= 1250 THEN 2
      WHEN claim_amount_arb <= 2250 THEN 3
      ELSE 4
    END AS segment_order,
    *
  FROM
    metrics
),

segment_summary AS (
  SELECT
    segment_order,
    COUNT(*) AS recipient_count,
    SUM(claim_amount_raw) AS claimed_raw,
    COUNTIF(positive_outflow_event_count_24h > 0)
      AS recipients_with_positive_outflow_24h,
    SUM(claim_linked_outflow_raw_24h) AS claim_linked_outflow_raw_24h,
    COUNTIF(positive_outflow_event_count_7d > 0)
      AS recipients_with_positive_outflow_7d,
    SUM(claim_linked_outflow_raw_7d) AS claim_linked_outflow_raw_7d
  FROM
    segment_labeled
  GROUP BY
    segment_order
),

segment_qa AS (
  SELECT
    COUNT(*) AS segment_count,
    SUM(recipient_count) AS segment_recipient_count,
    SUM(claimed_raw) AS segment_claimed_raw,
    SUM(claim_linked_outflow_raw_24h)
      AS segment_claim_linked_outflow_raw_24h,
    SUM(claim_linked_outflow_raw_7d)
      AS segment_claim_linked_outflow_raw_7d,
    COUNTIF(
      recipient_count <= 0
      OR recipients_with_positive_outflow_24h < 0
      OR recipients_with_positive_outflow_24h > recipient_count
      OR recipients_with_positive_outflow_7d < 0
      OR recipients_with_positive_outflow_7d > recipient_count
      OR recipients_with_positive_outflow_24h >
        recipients_with_positive_outflow_7d
      OR claim_linked_outflow_raw_24h < 0
      OR claim_linked_outflow_raw_24h > claimed_raw
      OR claim_linked_outflow_raw_7d < 0
      OR claim_linked_outflow_raw_7d > claimed_raw
      OR claim_linked_outflow_raw_24h > claim_linked_outflow_raw_7d
    ) AS invalid_segment_rows
  FROM
    segment_summary
),

timing_labeled AS (
  SELECT
    CASE
      WHEN seconds_to_first_positive_outflow_7d IS NULL THEN 6
      WHEN seconds_to_first_positive_outflow_7d < 3600 THEN 1
      WHEN seconds_to_first_positive_outflow_7d < 21600 THEN 2
      WHEN seconds_to_first_positive_outflow_7d < 86400 THEN 3
      WHEN seconds_to_first_positive_outflow_7d < 259200 THEN 4
      WHEN seconds_to_first_positive_outflow_7d < 604800 THEN 5
      ELSE 7
    END AS bucket_order
  FROM
    metrics
),

timing_summary AS (
  SELECT
    bucket_order,
    COUNT(*) AS recipient_count
  FROM
    timing_labeled
  GROUP BY
    bucket_order
),

timing_qa AS (
  SELECT
    COUNT(*) AS timing_bucket_count,
    SUM(recipient_count) AS timing_recipient_count,
    COUNTIF(bucket_order = 7) AS invalid_timing_bucket_rows
  FROM
    timing_summary
)

SELECT
  global.claim_rows,
  segment.segment_count,
  timing.timing_bucket_count,
  segment.segment_recipient_count,
  timing.timing_recipient_count,
  segment.invalid_segment_rows,
  timing.invalid_timing_bucket_rows,
  segment.segment_claimed_raw,
  global.claimed_raw AS source_claimed_raw,
  segment.segment_claim_linked_outflow_raw_24h,
  global.claim_linked_outflow_raw_24h
    AS source_claim_linked_outflow_raw_24h,
  segment.segment_claim_linked_outflow_raw_7d,
  global.claim_linked_outflow_raw_7d
    AS source_claim_linked_outflow_raw_7d,
  segment.segment_count = 4 AS expected_segment_count,
  timing.timing_bucket_count = 6 AS expected_timing_bucket_count,
  segment.segment_recipient_count = global.claim_rows
    AS segment_recipient_count_match,
  timing.timing_recipient_count = global.claim_rows
    AS timing_recipient_count_match,
  segment.segment_claimed_raw = global.claimed_raw
    AS segment_claimed_amount_match,
  segment.segment_claim_linked_outflow_raw_24h =
    global.claim_linked_outflow_raw_24h
    AS segment_claim_linked_outflow_24h_match,
  segment.segment_claim_linked_outflow_raw_7d =
    global.claim_linked_outflow_raw_7d
    AS segment_claim_linked_outflow_7d_match,
  segment.invalid_segment_rows = 0 AS segment_domain_checks_pass,
  timing.invalid_timing_bucket_rows = 0 AS timing_domain_checks_pass
FROM
  global_totals AS global
CROSS JOIN
  segment_qa AS segment
CROSS JOIN
  timing_qa AS timing;
