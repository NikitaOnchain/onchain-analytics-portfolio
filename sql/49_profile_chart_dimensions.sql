-- Profile observed claim sizes and first-positive-outflow timing buckets.
-- Always dry-run immediately before execution.
--
-- Output grain:
--   One JSON string containing one cohort summary, one row per observed claim
--   amount, and one row per mutually exclusive timing bucket.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.early_outflow_metrics_full_cohort
--   One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   No JOIN. Independent aggregations read the same claim-grain source.
--
-- Filters and time boundaries:
--   No claim rows are filtered. Timing buckets use the stored elapsed,
--   half-open seven-day metric: [claim timestamp, claim timestamp + 7 days).
--
-- Row-multiplication risk:
--   None. Each aggregation groups the claim-grain source directly. The final
--   JSON wrapper changes presentation only and does not alter counts.

WITH metrics AS (
  SELECT
    claim_amount_raw,
    claim_amount_raw / POW(CAST(10 AS BIGNUMERIC), 18) AS claim_amount_arb,
    seconds_to_first_positive_outflow_7d
  FROM
    `YOUR_DATASET_ID.early_outflow_metrics_full_cohort`
),

amount_frequency AS (
  SELECT
    claim_amount_arb,
    COUNT(*) AS recipient_count,
    SUM(claim_amount_raw) / POW(CAST(10 AS BIGNUMERIC), 18)
      AS claimed_arb
  FROM
    metrics
  GROUP BY
    claim_amount_arb
),

timing_labeled AS (
  SELECT
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
    END AS timing_bucket,
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

timing_frequency AS (
  SELECT
    bucket_order,
    timing_bucket,
    COUNT(*) AS recipient_count
  FROM
    timing_labeled
  GROUP BY
    bucket_order,
    timing_bucket
)

SELECT
  TO_JSON_STRING(STRUCT(
    (
      SELECT AS STRUCT
        COUNT(*) AS claim_rows,
        COUNT(DISTINCT claim_amount_arb) AS distinct_claim_amounts,
        MIN(claim_amount_arb) AS minimum_claim_amount_arb,
        MAX(claim_amount_arb) AS maximum_claim_amount_arb,
        APPROX_QUANTILES(claim_amount_arb, 100)[OFFSET(25)]
          AS approximate_p25_claim_amount_arb,
        APPROX_QUANTILES(claim_amount_arb, 100)[OFFSET(50)]
          AS approximate_median_claim_amount_arb,
        APPROX_QUANTILES(claim_amount_arb, 100)[OFFSET(75)]
          AS approximate_p75_claim_amount_arb
      FROM
        metrics
    ) AS cohort_summary,
    (
      SELECT
        ARRAY_AGG(STRUCT(
          claim_amount_arb,
          recipient_count,
          claimed_arb
        ) ORDER BY claim_amount_arb)
      FROM
        amount_frequency
    ) AS amount_frequencies,
    (
      SELECT
        ARRAY_AGG(STRUCT(
          bucket_order,
          timing_bucket,
          recipient_count
        ) ORDER BY bucket_order)
      FROM
        timing_frequency
    ) AS timing_frequencies
  )) AS chart_dimension_profile_json;
