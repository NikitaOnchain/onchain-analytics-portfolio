-- Aggregate bounded successful post-claim transaction events to one row per
-- corrected chunk-21 claim recipient.
-- Always dry-run the exact statement before execution.
--
-- Analytical meaning:
--   Metrics describe successful top-level transactions initiated by a claim
--   recipient after claim. They measure address activity, not retained human
--   usage, protocol engagement, token retention, or sales.
--
-- Output grain:
--   One row per validated claim event and unique claim recipient.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21
--     One validated claim event and unique recipient per row.
--   YOUR_DATASET_ID.post_claim_transaction_source_chunk_21
--     One successful source transaction per transaction hash.
--   YOUR_DATASET_ID.post_claim_activity_events_chunk_21
--     One block-ordered successful post-claim transaction per row.
--
-- Join keys and expected cardinality:
--   claim transaction hash to exact source receipt is many-to-one because a
--   transaction can contain several claim events.
--   LEFT JOIN to per-claim metrics uses exact claim event key
--   (claim_transaction_hash, claim_log_index), expected one-to-one after event
--   aggregation and retaining recipients with no post-claim activity.
--
-- Filters and time boundaries:
--   Event source already enforces strict block-aware order and the half-open
--   seven-elapsed-day window. The 24-hour subset is also half-open.
--   Active days use UTC calendar dates within the elapsed seven-day window.
--
-- Row-multiplication risk:
--   Events collapse to exact claim grain before the final LEFT JOIN. The exact
--   claim-receipt source is unique by transaction hash.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21`
CLUSTER BY
  claim_recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary claim-grain successful post-claim activity metrics for corrected claim chunk 21.'
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
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21`
),

claims_with_receipt AS (
  SELECT
    claim.*,
    receipt.block_hash AS claim_block_hash,
    receipt.transaction_index AS claim_transaction_index,
    receipt.from_address AS claim_transaction_sender
  FROM
    claims AS claim
  INNER JOIN
    `YOUR_DATASET_ID.post_claim_transaction_source_chunk_21` AS receipt
    ON claim.claim_transaction_hash = receipt.transaction_hash
),

per_claim AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNTIF(
      activity_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR)
    ) AS successful_transaction_count_24h,
    MIN(IF(
      activity_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR),
      activity_timestamp,
      NULL
    )) AS first_activity_timestamp_24h,
    COUNT(*) AS successful_transaction_count_7d,
    COUNT(DISTINCT DATE(activity_timestamp, 'UTC')) AS active_utc_day_count_7d,
    COUNT(DISTINCT activity_to_address) AS distinct_target_count_7d,
    MIN(activity_timestamp) AS first_activity_timestamp_7d
  FROM
    `YOUR_DATASET_ID.post_claim_activity_events_chunk_21`
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
  COALESCE(metric.active_utc_day_count_7d, 0) AS active_utc_day_count_7d,
  COALESCE(metric.distinct_target_count_7d, 0) AS distinct_target_count_7d,
  metric.first_activity_timestamp_7d,
  TIMESTAMP_DIFF(
    metric.first_activity_timestamp_7d,
    claim.claim_timestamp,
    SECOND
  ) AS seconds_to_first_activity_7d
FROM
  claims_with_receipt AS claim
LEFT JOIN
  per_claim AS metric
  USING (claim_transaction_hash, claim_log_index);

