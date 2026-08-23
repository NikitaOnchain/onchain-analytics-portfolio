-- Export compact, chart-ready full-cohort post-claim activity aggregates as
-- JSON. Always dry-run immediately before execution.
--
-- Analytical meaning:
--   Activity is a successful top-level Arbitrum transaction initiated by a
--   validated claim recipient after exact claim order. It is address activity,
--   not proof of retained human usage, protocol engagement, token retention,
--   or sales.
--
-- Output grain:
--   One JSON string containing four small datasets:
--   1) one row per elapsed window;
--   2) one row per claim-size segment;
--   3) one row per mutually exclusive first-activity timing bucket;
--   4) one row per mutually exclusive seven-day transaction-count bucket.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort
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
--   Claim-size boundaries reuse the observed approximate cohort quartiles
--   established for the early-outflow charts: 875, 1,250, and 2,250 ARB.

WITH metrics AS (
  SELECT
    claim_amount_raw,
    claim_amount_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS claim_amount_arb,
    successful_transaction_count_24h,
    successful_transaction_count_7d,
    active_utc_day_count_7d,
    distinct_target_count_7d,
    seconds_to_first_activity_7d
  FROM
    `YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort`
),

cohort_totals AS (
  SELECT
    COUNT(*) AS recipient_count,
    SUM(claim_amount_raw) AS claimed_raw,
    COUNTIF(successful_transaction_count_24h > 0)
      AS active_recipients_24h,
    SUM(successful_transaction_count_24h) AS activity_transaction_rows_24h,
    COUNTIF(successful_transaction_count_7d > 0)
      AS active_recipients_7d,
    SUM(successful_transaction_count_7d) AS activity_transaction_rows_7d,
    SUM(active_utc_day_count_7d) AS active_utc_day_count_7d,
    SUM(distinct_target_count_7d) AS distinct_target_count_7d
  FROM
    metrics
),

window_summary AS (
  SELECT
    1 AS window_order,
    'Within 24 hours' AS window_label,
    recipient_count,
    active_recipients_24h AS active_recipients,
    recipient_count - active_recipients_24h AS inactive_recipients,
    SAFE_DIVIDE(active_recipients_24h, recipient_count)
      AS active_recipient_rate,
    SAFE_DIVIDE(recipient_count - active_recipients_24h, recipient_count)
      AS inactive_recipient_rate,
    activity_transaction_rows_24h AS successful_transaction_rows,
    SAFE_DIVIDE(activity_transaction_rows_24h, recipient_count)
      AS average_transactions_per_recipient,
    SAFE_DIVIDE(activity_transaction_rows_24h, active_recipients_24h)
      AS average_transactions_per_active_recipient
  FROM
    cohort_totals

  UNION ALL

  SELECT
    2 AS window_order,
    'Within 7 days' AS window_label,
    recipient_count,
    active_recipients_7d AS active_recipients,
    recipient_count - active_recipients_7d AS inactive_recipients,
    SAFE_DIVIDE(active_recipients_7d, recipient_count)
      AS active_recipient_rate,
    SAFE_DIVIDE(recipient_count - active_recipients_7d, recipient_count)
      AS inactive_recipient_rate,
    activity_transaction_rows_7d AS successful_transaction_rows,
    SAFE_DIVIDE(activity_transaction_rows_7d, recipient_count)
      AS average_transactions_per_recipient,
    SAFE_DIVIDE(activity_transaction_rows_7d, active_recipients_7d)
      AS average_transactions_per_active_recipient
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
    COUNTIF(successful_transaction_count_24h > 0)
      AS active_recipients_24h,
    SUM(successful_transaction_count_24h) AS activity_transaction_rows_24h,
    COUNTIF(successful_transaction_count_7d > 0)
      AS active_recipients_7d,
    SUM(successful_transaction_count_7d) AS activity_transaction_rows_7d,
    SUM(active_utc_day_count_7d) AS active_utc_day_count_7d,
    SUM(distinct_target_count_7d) AS distinct_target_count_7d
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
    segment.active_recipients_24h,
    SAFE_DIVIDE(segment.active_recipients_24h, segment.recipient_count)
      AS active_recipient_rate_24h,
    segment.activity_transaction_rows_24h,
    SAFE_DIVIDE(
      segment.activity_transaction_rows_24h,
      segment.active_recipients_24h
    ) AS average_transactions_per_active_recipient_24h,
    segment.active_recipients_7d,
    SAFE_DIVIDE(segment.active_recipients_7d, segment.recipient_count)
      AS active_recipient_rate_7d,
    segment.activity_transaction_rows_7d,
    SAFE_DIVIDE(
      segment.activity_transaction_rows_7d,
      segment.active_recipients_7d
    ) AS average_transactions_per_active_recipient_7d,
    SAFE_DIVIDE(
      segment.active_utc_day_count_7d,
      segment.active_recipients_7d
    ) AS average_active_utc_days_per_active_recipient_7d,
    SAFE_DIVIDE(
      segment.distinct_target_count_7d,
      segment.active_recipients_7d
    ) AS average_distinct_targets_per_active_recipient_7d
  FROM
    segment_summary AS segment
  CROSS JOIN
    cohort_totals AS cohort
),

timing_labeled AS (
  SELECT
    CASE
      WHEN seconds_to_first_activity_7d IS NULL THEN 6
      WHEN seconds_to_first_activity_7d < 3600 THEN 1
      WHEN seconds_to_first_activity_7d < 21600 THEN 2
      WHEN seconds_to_first_activity_7d < 86400 THEN 3
      WHEN seconds_to_first_activity_7d < 259200 THEN 4
      WHEN seconds_to_first_activity_7d < 604800 THEN 5
      ELSE 7
    END AS bucket_order,
    CASE
      WHEN seconds_to_first_activity_7d IS NULL
        THEN 'No activity within 7d'
      WHEN seconds_to_first_activity_7d < 3600 THEN 'Within 1 hour'
      WHEN seconds_to_first_activity_7d < 21600 THEN '1 to <6 hours'
      WHEN seconds_to_first_activity_7d < 86400 THEN '6 to <24 hours'
      WHEN seconds_to_first_activity_7d < 259200 THEN '1 to <3 days'
      WHEN seconds_to_first_activity_7d < 604800 THEN '3 to <7 days'
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
),

intensity_labeled AS (
  SELECT
    CASE
      WHEN successful_transaction_count_7d = 0 THEN 1
      WHEN successful_transaction_count_7d = 1 THEN 2
      WHEN successful_transaction_count_7d <= 5 THEN 3
      WHEN successful_transaction_count_7d <= 10 THEN 4
      ELSE 5
    END AS bucket_order,
    CASE
      WHEN successful_transaction_count_7d = 0
        THEN 'No activity within 7d'
      WHEN successful_transaction_count_7d = 1 THEN '1 transaction'
      WHEN successful_transaction_count_7d <= 5 THEN '2–5 transactions'
      WHEN successful_transaction_count_7d <= 10 THEN '6–10 transactions'
      ELSE '11+ transactions'
    END AS transaction_count_bucket,
    successful_transaction_count_7d
  FROM
    metrics
),

intensity_summary AS (
  SELECT
    intensity.bucket_order,
    intensity.transaction_count_bucket,
    COUNT(*) AS recipient_count,
    SAFE_DIVIDE(COUNT(*), cohort.recipient_count) AS recipient_share,
    SUM(successful_transaction_count_7d) AS successful_transaction_rows,
    SAFE_DIVIDE(
      SUM(successful_transaction_count_7d),
      cohort.activity_transaction_rows_7d
    ) AS successful_transaction_share
  FROM
    intensity_labeled AS intensity
  CROSS JOIN
    cohort_totals AS cohort
  GROUP BY
    intensity.bucket_order,
    intensity.transaction_count_bucket,
    cohort.recipient_count,
    cohort.activity_transaction_rows_7d
)

SELECT
  TO_JSON_STRING(STRUCT(
    '2023-03-23 through 2023-09-24 claim cohort' AS cohort,
    'Successful top-level Arbitrum transactions initiated by the validated claim recipient after exact claim order'
      AS activity_definition,
    'Address activity; not proof of retained human usage, protocol engagement, token retention, or sales'
      AS interpretation_limit,
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
    ) AS first_activity_timing,
    (
      SELECT ARRAY_AGG(intensity_row ORDER BY bucket_order)
      FROM intensity_summary AS intensity_row
    ) AS activity_intensity_7d
  )) AS chart_data_json;
