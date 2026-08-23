-- Profile and reconcile claim-grain bounded post-claim activity metrics for
-- corrected claim chunk 21.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One QA and bounded-results summary row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21
--     Intended grain is one row per unique claim recipient.
--   YOUR_DATASET_ID.post_claim_activity_events_chunk_21
--     One successful block-ordered post-claim transaction per row.
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21
--     One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   No JOIN is used. Scalar subqueries reconcile claim and event controls
--   without multiplying rows.
--
-- Filters and time boundaries:
--   Stored metrics use half-open elapsed 24-hour and seven-day windows after
--   exact claim, with block-aware transaction ordering.
--
-- Row-multiplication risk:
--   None. Recipient and exact claim-event grain, NULL/domain rules, window
--   monotonicity, and event-to-metric totals are checked explicitly.

WITH metrics AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21`
),

claims AS (
  SELECT
    COUNT(*) AS claim_rows,
    COUNT(DISTINCT recipient) AS distinct_claim_recipients,
    SUM(amount_raw) AS claimed_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21`
),

events AS (
  SELECT
    COUNT(*) AS event_rows_7d,
    COUNTIF(
      activity_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR)
    ) AS event_rows_24h,
    COUNT(DISTINCT claim_recipient) AS active_recipients_7d
  FROM
    `YOUR_DATASET_ID.post_claim_activity_events_chunk_21`
)

SELECT
  COUNT(*) AS metric_rows,
  COUNT(DISTINCT claim_recipient) AS distinct_metric_recipients,
  COUNT(DISTINCT CONCAT(
    claim_transaction_hash,
    ':',
    CAST(claim_log_index AS STRING)
  )) AS distinct_claim_event_keys,
  COUNT(*) - COUNT(DISTINCT claim_recipient)
    AS duplicate_rows_above_recipient_grain,
  COUNTIF(
    claim_timestamp IS NULL
    OR claim_block_number IS NULL
    OR claim_block_hash IS NULL
    OR claim_transaction_hash IS NULL
    OR claim_transaction_index IS NULL
    OR claim_log_index IS NULL
    OR claim_recipient IS NULL
    OR claim_transaction_sender IS NULL
    OR claim_was_delegated IS NULL
    OR claim_amount_raw IS NULL
    OR successful_transaction_count_24h IS NULL
    OR successful_transaction_count_7d IS NULL
    OR active_utc_day_count_7d IS NULL
    OR distinct_target_count_7d IS NULL
  ) AS critical_null_rows,
  COUNTIF(
    successful_transaction_count_24h < 0
    OR successful_transaction_count_7d < 0
    OR active_utc_day_count_7d < 0
    OR distinct_target_count_7d < 0
  ) AS negative_metric_rows,
  COUNTIF(
    successful_transaction_count_24h > successful_transaction_count_7d
  ) AS window_monotonicity_violation_rows,
  COUNTIF(active_utc_day_count_7d > successful_transaction_count_7d)
    AS active_day_domain_violation_rows,
  COUNTIF(distinct_target_count_7d > successful_transaction_count_7d)
    AS distinct_target_domain_violation_rows,
  COUNTIF(
    (successful_transaction_count_24h = 0)
      != (first_activity_timestamp_24h IS NULL)
    OR (successful_transaction_count_24h = 0)
      != (seconds_to_first_activity_24h IS NULL)
    OR (successful_transaction_count_7d = 0)
      != (first_activity_timestamp_7d IS NULL)
    OR (successful_transaction_count_7d = 0)
      != (seconds_to_first_activity_7d IS NULL)
  ) AS first_activity_null_alignment_violation_rows,
  COUNTIF(
    seconds_to_first_activity_24h < 0
    OR seconds_to_first_activity_24h >= 24 * 60 * 60
    OR seconds_to_first_activity_7d < 0
    OR seconds_to_first_activity_7d >= 7 * 24 * 60 * 60
  ) AS first_activity_window_violation_rows,
  COUNTIF(claim_was_delegated) AS delegated_claim_recipients,
  COUNTIF(successful_transaction_count_24h > 0) AS active_recipients_24h,
  COUNTIF(successful_transaction_count_7d > 0) AS active_recipients_7d,
  COUNTIF(successful_transaction_count_7d = 0) AS inactive_recipients_7d,
  SAFE_DIVIDE(
    COUNTIF(successful_transaction_count_24h > 0),
    COUNT(*)
  ) AS active_recipient_rate_24h,
  SAFE_DIVIDE(
    COUNTIF(successful_transaction_count_7d > 0),
    COUNT(*)
  ) AS active_recipient_rate_7d,
  SUM(successful_transaction_count_24h) AS stored_transaction_count_24h,
  SUM(successful_transaction_count_7d) AS stored_transaction_count_7d,
  SUM(active_utc_day_count_7d) AS stored_active_utc_days_7d,
  APPROX_QUANTILES(
    IF(successful_transaction_count_7d > 0, successful_transaction_count_7d, NULL),
    100
  )[OFFSET(50)] AS approximate_median_transactions_per_active_recipient_7d,
  SUM(claim_amount_raw) AS stored_claimed_raw,
  ANY_VALUE(claims.claim_rows) AS expected_claim_rows,
  ANY_VALUE(claims.distinct_claim_recipients)
    AS expected_distinct_claim_recipients,
  ANY_VALUE(claims.claimed_raw) AS expected_claimed_raw,
  ANY_VALUE(events.event_rows_24h) AS expected_transaction_count_24h,
  ANY_VALUE(events.event_rows_7d) AS expected_transaction_count_7d,
  ANY_VALUE(events.active_recipients_7d) AS expected_active_recipients_7d
FROM
  metrics
CROSS JOIN
  claims
CROSS JOIN
  events;
