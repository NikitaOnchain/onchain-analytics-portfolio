-- Export compact, chart-ready full-cohort early-outflow aggregates as JSON.
-- Always dry-run immediately before execution.
--
-- Output grain:
--   One JSON string containing three small datasets:
--   1) one row per elapsed window;
--   2) one row per claim-size segment;
--   3) one row per mutually exclusive first-positive-outflow timing bucket.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.early_outflow_metrics_full_cohort
--   One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   No row-level JOIN. Independent aggregations read the same claim-grain
--   source. Window rows are reshaped from one cohort-total row.
--
-- Filters and time boundaries:
--   No claim rows are filtered. Stored metrics use elapsed, half-open windows
--   of [claim timestamp, +24 hours) and [claim timestamp, +7 days).
--
-- Row-multiplication risk:
--   None. Every chart dataset aggregates the claim-grain source directly.
--
-- Segment policy:
--   Boundaries are the observed approximate cohort quartiles from
--   sql/49_profile_chart_dimensions.sql: 875, 1,250, and 2,250 ARB.

WITH metrics AS (
  SELECT
    claim_amount_raw,
    claim_amount_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS claim_amount_arb,
    positive_outflow_event_count_24h,
    gross_positive_outflow_raw_24h,
    claim_linked_outflow_raw_24h,
    positive_outflow_event_count_7d,
    gross_positive_outflow_raw_7d,
    claim_linked_outflow_raw_7d,
    seconds_to_first_positive_outflow_7d
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_full_cohort`
),

cohort_totals AS (
  SELECT
    COUNT(*) AS recipient_count,
    SUM(claim_amount_raw) AS claimed_raw,
    COUNTIF(positive_outflow_event_count_24h > 0)
      AS recipients_with_positive_outflow_24h,
    SUM(gross_positive_outflow_raw_24h) AS gross_positive_outflow_raw_24h,
    SUM(claim_linked_outflow_raw_24h) AS claim_linked_outflow_raw_24h,
    COUNTIF(positive_outflow_event_count_7d > 0)
      AS recipients_with_positive_outflow_7d,
    SUM(gross_positive_outflow_raw_7d) AS gross_positive_outflow_raw_7d,
    SUM(claim_linked_outflow_raw_7d) AS claim_linked_outflow_raw_7d
  FROM
    metrics
),

window_summary AS (
  SELECT
    1 AS window_order,
    'Within 24 hours' AS window_label,
    recipient_count,
    recipients_with_positive_outflow_24h
      AS recipients_with_positive_outflow,
    recipient_count - recipients_with_positive_outflow_24h
      AS recipients_without_positive_outflow,
    SAFE_DIVIDE(recipients_with_positive_outflow_24h, recipient_count)
      AS recipient_positive_outflow_rate,
    SAFE_DIVIDE(
      recipient_count - recipients_with_positive_outflow_24h,
      recipient_count
    ) AS recipient_no_positive_outflow_rate,
    claimed_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS claimed_arb,
    gross_positive_outflow_raw_24h / POW(CAST(10 AS BIGNUMERIC), 18)
      AS gross_positive_outflow_arb,
    claim_linked_outflow_raw_24h / POW(CAST(10 AS BIGNUMERIC), 18)
      AS claim_linked_outflow_arb,
    SAFE_DIVIDE(claim_linked_outflow_raw_24h, claimed_raw)
      AS claim_linked_outflow_share,
    (claimed_raw - claim_linked_outflow_raw_24h) /
      POW(CAST(10 AS BIGNUMERIC), 18) AS retained_claim_proxy_arb,
    SAFE_DIVIDE(claimed_raw - claim_linked_outflow_raw_24h, claimed_raw)
      AS retained_claim_proxy_share
  FROM
    cohort_totals

  UNION ALL

  SELECT
    2 AS window_order,
    'Within 7 days' AS window_label,
    recipient_count,
    recipients_with_positive_outflow_7d
      AS recipients_with_positive_outflow,
    recipient_count - recipients_with_positive_outflow_7d
      AS recipients_without_positive_outflow,
    SAFE_DIVIDE(recipients_with_positive_outflow_7d, recipient_count)
      AS recipient_positive_outflow_rate,
    SAFE_DIVIDE(
      recipient_count - recipients_with_positive_outflow_7d,
      recipient_count
    ) AS recipient_no_positive_outflow_rate,
    claimed_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS claimed_arb,
    gross_positive_outflow_raw_7d / POW(CAST(10 AS BIGNUMERIC), 18)
      AS gross_positive_outflow_arb,
    claim_linked_outflow_raw_7d / POW(CAST(10 AS BIGNUMERIC), 18)
      AS claim_linked_outflow_arb,
    SAFE_DIVIDE(claim_linked_outflow_raw_7d, claimed_raw)
      AS claim_linked_outflow_share,
    (claimed_raw - claim_linked_outflow_raw_7d) /
      POW(CAST(10 AS BIGNUMERIC), 18) AS retained_claim_proxy_arb,
    SAFE_DIVIDE(claimed_raw - claim_linked_outflow_raw_7d, claimed_raw)
      AS retained_claim_proxy_share
  FROM
    cohort_totals
),

segment_labeled AS (
  SELECT
    CASE
      WHEN claim_amount_arb <= 875 THEN 1
      WHEN claim_amount_arb <= 1250 THEN 2
      WHEN claim_amount_arb <= 2250 THEN 3
      ELSE 4
    END AS segment_order,
    CASE
      WHEN claim_amount_arb <= 875 THEN '625–875 ARB'
      WHEN claim_amount_arb <= 1250 THEN '1,125–1,250 ARB'
      WHEN claim_amount_arb <= 2250 THEN '1,500–2,250 ARB'
      ELSE '2,500–10,250 ARB'
    END AS claim_size_segment,
    *
  FROM
    metrics
),

segment_summary AS (
  SELECT
    segment_order,
    claim_size_segment,
    MIN(claim_amount_arb) AS minimum_claim_amount_arb,
    MAX(claim_amount_arb) AS maximum_claim_amount_arb,
    COUNT(*) AS recipient_count,
    SUM(claim_amount_raw) AS claimed_raw,
    COUNTIF(positive_outflow_event_count_24h > 0)
      AS recipients_with_positive_outflow_24h,
    SUM(gross_positive_outflow_raw_24h) AS gross_positive_outflow_raw_24h,
    SUM(claim_linked_outflow_raw_24h) AS claim_linked_outflow_raw_24h,
    COUNTIF(positive_outflow_event_count_7d > 0)
      AS recipients_with_positive_outflow_7d,
    SUM(gross_positive_outflow_raw_7d) AS gross_positive_outflow_raw_7d,
    SUM(claim_linked_outflow_raw_7d) AS claim_linked_outflow_raw_7d
  FROM
    segment_labeled
  GROUP BY
    segment_order,
    claim_size_segment
),

segment_chart AS (
  SELECT
    segment.segment_order,
    segment.claim_size_segment,
    segment.minimum_claim_amount_arb,
    segment.maximum_claim_amount_arb,
    segment.recipient_count,
    SAFE_DIVIDE(segment.recipient_count, cohort.recipient_count)
      AS recipient_share,
    segment.claimed_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS claimed_arb,
    SAFE_DIVIDE(segment.claimed_raw, cohort.claimed_raw) AS claimed_share,
    segment.recipients_with_positive_outflow_24h,
    SAFE_DIVIDE(
      segment.recipients_with_positive_outflow_24h,
      segment.recipient_count
    ) AS recipient_positive_outflow_rate_24h,
    segment.gross_positive_outflow_raw_24h /
      POW(CAST(10 AS BIGNUMERIC), 18) AS gross_positive_outflow_arb_24h,
    segment.claim_linked_outflow_raw_24h /
      POW(CAST(10 AS BIGNUMERIC), 18) AS claim_linked_outflow_arb_24h,
    SAFE_DIVIDE(segment.claim_linked_outflow_raw_24h, segment.claimed_raw)
      AS claim_linked_outflow_share_24h,
    SAFE_DIVIDE(
      segment.claimed_raw - segment.claim_linked_outflow_raw_24h,
      segment.claimed_raw
    ) AS retained_claim_proxy_share_24h,
    segment.recipients_with_positive_outflow_7d,
    SAFE_DIVIDE(
      segment.recipients_with_positive_outflow_7d,
      segment.recipient_count
    ) AS recipient_positive_outflow_rate_7d,
    segment.gross_positive_outflow_raw_7d /
      POW(CAST(10 AS BIGNUMERIC), 18) AS gross_positive_outflow_arb_7d,
    segment.claim_linked_outflow_raw_7d /
      POW(CAST(10 AS BIGNUMERIC), 18) AS claim_linked_outflow_arb_7d,
    SAFE_DIVIDE(segment.claim_linked_outflow_raw_7d, segment.claimed_raw)
      AS claim_linked_outflow_share_7d,
    SAFE_DIVIDE(
      segment.claimed_raw - segment.claim_linked_outflow_raw_7d,
      segment.claimed_raw
    ) AS retained_claim_proxy_share_7d
  FROM
    segment_summary AS segment
  CROSS JOIN
    cohort_totals AS cohort
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
    END AS bucket_order,
    CASE
      WHEN seconds_to_first_positive_outflow_7d IS NULL
        THEN 'No positive outflow within 7d'
      WHEN seconds_to_first_positive_outflow_7d < 3600
        THEN 'Within 1 hour'
      WHEN seconds_to_first_positive_outflow_7d < 21600
        THEN '1 to <6 hours'
      WHEN seconds_to_first_positive_outflow_7d < 86400
        THEN '6 to <24 hours'
      WHEN seconds_to_first_positive_outflow_7d < 259200
        THEN '1 to <3 days'
      WHEN seconds_to_first_positive_outflow_7d < 604800
        THEN '3 to <7 days'
      ELSE 'Invalid: outside seven-day window'
    END AS timing_bucket
  FROM
    metrics
),

timing_summary AS (
  SELECT
    timing.bucket_order,
    timing.timing_bucket,
    COUNT(*) AS recipient_count,
    SAFE_DIVIDE(COUNT(*), cohort.recipient_count) AS recipient_share
  FROM
    timing_labeled AS timing
  CROSS JOIN
    cohort_totals AS cohort
  GROUP BY
    timing.bucket_order,
    timing.timing_bucket,
    cohort.recipient_count
)

SELECT
  TO_JSON_STRING(STRUCT(
    '2023-03-23 through 2023-09-24 claim cohort' AS cohort,
    'Positive non-self ARB transfers; not classified as sales'
      AS outflow_definition,
    'Capped at each claim amount; proxy because ARB is fungible'
      AS claim_linked_outflow_definition,
    (
      SELECT ARRAY_AGG(window_row ORDER BY window_order)
      FROM window_summary AS window_row
    ) AS window_summary,
    (
      SELECT ARRAY_AGG(segment_row ORDER BY segment_order)
      FROM segment_chart AS segment_row
    ) AS claim_size_segments,
    (
      SELECT ARRAY_AGG(timing_row ORDER BY bucket_order)
      FROM timing_summary AS timing_row
    ) AS first_positive_outflow_timing
  )) AS chart_data_json;
