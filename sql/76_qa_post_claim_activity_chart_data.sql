-- Reconcile compact post-claim activity chart dimensions to the validated
-- full-cohort claim-grain table. Always dry-run immediately before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort
--   One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   No row-level JOIN. CROSS JOINs attach one-row global totals to aggregate
--   summaries and therefore do not multiply claim rows.
--
-- Filters and time boundaries:
--   No claim rows are filtered. Timing labels cover the stored elapsed,
--   half-open seven-day window plus the no-activity state.
--
-- Row-multiplication risk:
--   None at claim grain. Segment, timing, and intensity summaries are checked
--   independently against the same global source totals.

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

global_totals AS (
  SELECT
    COUNT(*) AS claim_rows,
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
    segment_order
),

segment_qa AS (
  SELECT
    COUNT(*) AS segment_count,
    SUM(recipient_count) AS segment_recipient_count,
    SUM(claimed_raw) AS segment_claimed_raw,
    SUM(active_recipients_24h) AS segment_active_recipients_24h,
    SUM(activity_transaction_rows_24h)
      AS segment_activity_transaction_rows_24h,
    SUM(active_recipients_7d) AS segment_active_recipients_7d,
    SUM(activity_transaction_rows_7d)
      AS segment_activity_transaction_rows_7d,
    SUM(active_utc_day_count_7d) AS segment_active_utc_day_count_7d,
    SUM(distinct_target_count_7d) AS segment_distinct_target_count_7d,
    COUNTIF(
      recipient_count <= 0
      OR active_recipients_24h < 0
      OR active_recipients_24h > recipient_count
      OR active_recipients_7d < 0
      OR active_recipients_7d > recipient_count
      OR active_recipients_24h > active_recipients_7d
      OR activity_transaction_rows_24h < active_recipients_24h
      OR activity_transaction_rows_7d < active_recipients_7d
      OR activity_transaction_rows_24h > activity_transaction_rows_7d
      OR active_utc_day_count_7d < active_recipients_7d
      OR active_utc_day_count_7d > activity_transaction_rows_7d
      OR distinct_target_count_7d > activity_transaction_rows_7d
    ) AS invalid_segment_rows
  FROM
    segment_summary
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
    SUM(IF(bucket_order BETWEEN 1 AND 3, recipient_count, 0))
      AS timing_active_recipients_24h,
    SUM(IF(bucket_order BETWEEN 1 AND 5, recipient_count, 0))
      AS timing_active_recipients_7d,
    COUNTIF(bucket_order = 7) AS invalid_timing_bucket_rows
  FROM
    timing_summary
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
    successful_transaction_count_7d
  FROM
    metrics
),

intensity_summary AS (
  SELECT
    bucket_order,
    COUNT(*) AS recipient_count,
    SUM(successful_transaction_count_7d) AS activity_transaction_rows_7d
  FROM
    intensity_labeled
  GROUP BY
    bucket_order
),

intensity_qa AS (
  SELECT
    COUNT(*) AS intensity_bucket_count,
    SUM(recipient_count) AS intensity_recipient_count,
    SUM(IF(bucket_order = 1, recipient_count, 0))
      AS intensity_inactive_recipients_7d,
    SUM(activity_transaction_rows_7d)
      AS intensity_activity_transaction_rows_7d,
    COUNTIF(
      recipient_count <= 0
      OR activity_transaction_rows_7d < 0
      OR (bucket_order = 1 AND activity_transaction_rows_7d != 0)
      OR (bucket_order > 1 AND activity_transaction_rows_7d < recipient_count)
    ) AS invalid_intensity_bucket_rows
  FROM
    intensity_summary
)

SELECT
  global.claim_rows,
  segment.segment_count,
  timing.timing_bucket_count,
  intensity.intensity_bucket_count,
  segment.segment_recipient_count,
  timing.timing_recipient_count,
  intensity.intensity_recipient_count,
  segment.invalid_segment_rows,
  timing.invalid_timing_bucket_rows,
  intensity.invalid_intensity_bucket_rows,
  segment.segment_claimed_raw,
  global.claimed_raw AS source_claimed_raw,
  segment.segment_active_recipients_24h,
  global.active_recipients_24h AS source_active_recipients_24h,
  segment.segment_active_recipients_7d,
  global.active_recipients_7d AS source_active_recipients_7d,
  segment.segment_activity_transaction_rows_24h,
  global.activity_transaction_rows_24h
    AS source_activity_transaction_rows_24h,
  segment.segment_activity_transaction_rows_7d,
  global.activity_transaction_rows_7d
    AS source_activity_transaction_rows_7d,
  segment.segment_active_utc_day_count_7d,
  global.active_utc_day_count_7d AS source_active_utc_day_count_7d,
  segment.segment_distinct_target_count_7d,
  global.distinct_target_count_7d AS source_distinct_target_count_7d,
  timing.timing_active_recipients_24h,
  timing.timing_active_recipients_7d,
  intensity.intensity_inactive_recipients_7d,
  intensity.intensity_activity_transaction_rows_7d,
  segment.segment_count = 4 AS expected_segment_count,
  timing.timing_bucket_count = 6 AS expected_timing_bucket_count,
  intensity.intensity_bucket_count = 5 AS expected_intensity_bucket_count,
  segment.segment_recipient_count = global.claim_rows
    AS segment_recipient_count_match,
  timing.timing_recipient_count = global.claim_rows
    AS timing_recipient_count_match,
  intensity.intensity_recipient_count = global.claim_rows
    AS intensity_recipient_count_match,
  segment.segment_claimed_raw = global.claimed_raw
    AS segment_claimed_amount_match,
  segment.segment_active_recipients_24h = global.active_recipients_24h
    AS segment_active_recipients_24h_match,
  segment.segment_active_recipients_7d = global.active_recipients_7d
    AS segment_active_recipients_7d_match,
  segment.segment_activity_transaction_rows_24h =
    global.activity_transaction_rows_24h
    AS segment_activity_rows_24h_match,
  segment.segment_activity_transaction_rows_7d =
    global.activity_transaction_rows_7d
    AS segment_activity_rows_7d_match,
  segment.segment_active_utc_day_count_7d = global.active_utc_day_count_7d
    AS segment_active_day_count_7d_match,
  segment.segment_distinct_target_count_7d = global.distinct_target_count_7d
    AS segment_distinct_target_count_7d_match,
  timing.timing_active_recipients_24h = global.active_recipients_24h
    AS timing_active_recipients_24h_match,
  timing.timing_active_recipients_7d = global.active_recipients_7d
    AS timing_active_recipients_7d_match,
  intensity.intensity_inactive_recipients_7d =
    global.claim_rows - global.active_recipients_7d
    AS intensity_inactive_recipients_7d_match,
  intensity.intensity_activity_transaction_rows_7d =
    global.activity_transaction_rows_7d
    AS intensity_activity_rows_7d_match,
  segment.invalid_segment_rows = 0 AS segment_domain_checks_pass,
  timing.invalid_timing_bucket_rows = 0 AS timing_domain_checks_pass,
  intensity.invalid_intensity_bucket_rows = 0
    AS intensity_domain_checks_pass
FROM
  global_totals AS global
CROSS JOIN
  segment_qa AS segment
CROSS JOIN
  timing_qa AS timing
CROSS JOIN
  intensity_qa AS intensity;
