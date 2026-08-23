-- Assemble full-cohort post-claim activity metrics from validated compact
-- source-chunk partials. Always dry-run the exact statement before execution.
--
-- Analytical meaning:
--   Metrics describe successful top-level transactions initiated by a
--   validated claim recipient after exact claim order. They measure address
--   activity, not retained human usage, protocol engagement, token retention,
--   or sales.
--
-- Output grain:
--   One row per validated claim event and unique claim recipient, including
--   recipients with zero qualifying transactions in both elapsed windows.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row.
--   YOUR_DATASET_ID.post_claim_transaction_order_batch_*
--     One exact claim transaction per unique transaction hash in each
--     non-overlapping order batch.
--   YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_*
--     One active exact claim event per non-overlapping source chunk.
--
-- Join keys and expected cardinality:
--   Claim transaction hash to compact order key is many-to-one from claim
--   events because a transaction can contain several claims.
--   Partial metrics aggregate to exact claim key
--   (claim_transaction_hash, claim_log_index), then join one-to-one to claims.
--
-- Filters and time boundaries:
--   Only final two-digit claim and partial table suffixes are used.
--   Every partial already applies strict block-aware ordering and the half-open
--   elapsed 24-hour and seven-day windows across source coverage
--   [2023-03-23, 2023-10-02) UTC.
--
-- Row-multiplication risk:
--   A claim can appear in several partial chunks when its seven-day window
--   crosses source boundaries. Scalar metrics are summed/minimized by exact
--   claim key; UTC dates and target addresses are re-deduplicated across all
--   partial arrays before the final one-to-one joins.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort`
CLUSTER BY
  claim_recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary full-cohort claim-grain successful post-claim address-activity metrics assembled from validated compact source-chunk partials.'
)
AS
WITH claims AS (
  SELECT
    chunk_number,
    block_timestamp AS claim_timestamp,
    block_number AS claim_block_number,
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    LOWER(recipient) AS claim_recipient,
    amount_raw AS claim_amount_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

claims_with_order AS (
  SELECT
    claim.*,
    claim_order.claim_block_hash,
    claim_order.claim_transaction_index,
    claim_order.claim_transaction_sender
  FROM
    claims AS claim
  INNER JOIN
    `YOUR_DATASET_ID.post_claim_transaction_order_batch_*` AS claim_order
    USING (claim_transaction_hash)
),

partial AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

scalar_metrics AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    SUM(successful_transaction_count_24h_partial)
      AS successful_transaction_count_24h,
    MIN(first_activity_timestamp_24h_partial)
      AS first_activity_timestamp_24h,
    SUM(successful_transaction_count_7d_partial)
      AS successful_transaction_count_7d,
    MIN(first_activity_timestamp_7d_partial)
      AS first_activity_timestamp_7d
  FROM
    partial
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

active_dates AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNT(DISTINCT active_date) AS active_utc_day_count_7d
  FROM
    partial
  CROSS JOIN
    UNNEST(active_utc_dates_7d_partial) AS active_date
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

target_addresses AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNT(DISTINCT target_address) AS distinct_target_count_7d
  FROM
    partial
  CROSS JOIN
    UNNEST(target_addresses_7d_partial) AS target_address
  GROUP BY
    claim_transaction_hash,
    claim_log_index
)

SELECT
  claim.chunk_number,
  claim.claim_timestamp,
  claim.claim_block_number,
  claim.claim_block_hash,
  claim.claim_transaction_hash,
  claim.claim_transaction_index,
  claim.claim_log_index,
  claim.claim_recipient,
  claim.claim_transaction_sender,
  claim.claim_transaction_sender != claim.claim_recipient
    AS claim_was_delegated,
  claim.claim_amount_raw,
  COALESCE(metric.successful_transaction_count_24h, 0)
    AS successful_transaction_count_24h,
  metric.first_activity_timestamp_24h,
  TIMESTAMP_DIFF(
    metric.first_activity_timestamp_24h,
    claim.claim_timestamp,
    SECOND
  ) AS seconds_to_first_activity_24h,
  COALESCE(metric.successful_transaction_count_7d, 0)
    AS successful_transaction_count_7d,
  COALESCE(date_metric.active_utc_day_count_7d, 0)
    AS active_utc_day_count_7d,
  COALESCE(target_metric.distinct_target_count_7d, 0)
    AS distinct_target_count_7d,
  metric.first_activity_timestamp_7d,
  TIMESTAMP_DIFF(
    metric.first_activity_timestamp_7d,
    claim.claim_timestamp,
    SECOND
  ) AS seconds_to_first_activity_7d
FROM
  claims_with_order AS claim
LEFT JOIN
  scalar_metrics AS metric
  USING (claim_transaction_hash, claim_log_index)
LEFT JOIN
  active_dates AS date_metric
  USING (claim_transaction_hash, claim_log_index)
LEFT JOIN
  target_addresses AS target_metric
  USING (claim_transaction_hash, claim_log_index);

