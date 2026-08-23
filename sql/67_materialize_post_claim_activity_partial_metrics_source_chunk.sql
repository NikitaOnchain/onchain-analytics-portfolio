-- Materialize compact post-claim activity metrics from one successful-
-- transaction source chunk. Always update the target suffix, source table,
-- source chunk number, and both UTC bounds together. Dry-run the exact
-- statement immediately before execution.
--
-- Configuration in this saved example:
--   Source chunk 01, half-open interval 2023-03-23 through 2023-03-27 UTC.
--
-- Analytical meaning:
--   Metrics describe successful top-level transactions initiated by a
--   validated claim recipient after that recipient's exact claim order. They
--   measure address activity, not retained human usage, protocol engagement,
--   token retention, or sales.
--
-- Output grain:
--   One exact claim event with at least one qualifying activity transaction in
--   source chunk 01, keyed by (claim_transaction_hash, claim_log_index).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row.
--   YOUR_DATASET_ID.post_claim_transaction_order_batch_*
--     One exact claim transaction per unique transaction hash in each
--     non-overlapping order batch.
--   YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_01
--     One successful relevant top-level transaction per unique hash.
--
-- Join keys and expected cardinality:
--   claim transaction hash to compact order key is many-to-one because one
--   transaction can contain several claim events.
--   claim recipient to source from_address is intentionally one-to-many.
--
-- Filters and time boundaries:
--   Source rows are restricted to [2023-03-23, 2023-03-27) UTC.
--   Claims must have a seven-day window overlapping that interval.
--   Activity excludes the exact claim transaction, is strictly later by
--   (block_number, transaction_index), and falls in the half-open elapsed
--   seven-day window after claim. The 24-hour subset is also half-open.
--
-- Row-multiplication risk:
--   The recipient-to-activity join intentionally creates one row per
--   qualifying transaction before aggregation. Claim-event and source-
--   transaction uniqueness are prerequisites and are rechecked by SQL 68.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_01`
CLUSTER BY
  claim_recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary compact post-claim activity partial metrics from successful-transaction source chunk 01.'
)
AS
WITH claims AS (
  SELECT
    chunk_number AS claim_chunk_number,
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
    AND block_timestamp < TIMESTAMP('2023-03-27 00:00:00+00')
    AND TIMESTAMP_ADD(block_timestamp, INTERVAL 7 DAY)
      > TIMESTAMP('2023-03-23 00:00:00+00')
),

claims_with_order AS (
  SELECT
    claim.*,
    claim_order.claim_receipt_timestamp,
    claim_order.claim_receipt_block_number,
    claim_order.claim_block_hash,
    claim_order.claim_transaction_index,
    claim_order.claim_transaction_sender
  FROM
    claims AS claim
  INNER JOIN
    `YOUR_DATASET_ID.post_claim_transaction_order_batch_*` AS claim_order
    USING (claim_transaction_hash)
),

source AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_01`
  WHERE
    source_chunk_number = 1
    AND block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-27 00:00:00+00')
    AND initiated_by_claim_recipient
),

activity_matches AS (
  SELECT
    1 AS source_chunk_number,
    claim.claim_chunk_number,
    claim.claim_timestamp,
    claim.claim_block_number,
    claim.claim_block_hash,
    claim.claim_transaction_hash,
    claim.claim_transaction_index,
    claim.claim_log_index,
    claim.claim_recipient,
    claim.claim_transaction_sender,
    claim.claim_amount_raw,
    activity.block_timestamp AS activity_timestamp,
    activity.transaction_hash AS activity_transaction_hash,
    activity.to_address AS activity_to_address
  FROM
    claims_with_order AS claim
  INNER JOIN
    source AS activity
    ON claim.claim_recipient = activity.from_address
  WHERE
    activity.transaction_hash != claim.claim_transaction_hash
    AND (
      activity.block_number > claim.claim_receipt_block_number
      OR (
        activity.block_number = claim.claim_receipt_block_number
        AND activity.transaction_index > claim.claim_transaction_index
      )
    )
    AND activity.block_timestamp >= claim.claim_timestamp
    AND activity.block_timestamp
      < TIMESTAMP_ADD(claim.claim_timestamp, INTERVAL 7 DAY)
),

scalar_metrics AS (
  SELECT
    source_chunk_number,
    claim_chunk_number,
    claim_timestamp,
    claim_block_number,
    claim_block_hash,
    claim_transaction_hash,
    claim_transaction_index,
    claim_log_index,
    claim_recipient,
    claim_transaction_sender,
    claim_amount_raw,
    COUNTIF(
      activity_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR)
    ) AS successful_transaction_count_24h_partial,
    MIN(IF(
      activity_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR),
      activity_timestamp,
      NULL
    )) AS first_activity_timestamp_24h_partial,
    COUNT(*) AS successful_transaction_count_7d_partial,
    MIN(activity_timestamp) AS first_activity_timestamp_7d_partial
  FROM
    activity_matches
  GROUP BY
    source_chunk_number,
    claim_chunk_number,
    claim_timestamp,
    claim_block_number,
    claim_block_hash,
    claim_transaction_hash,
    claim_transaction_index,
    claim_log_index,
    claim_recipient,
    claim_transaction_sender,
    claim_amount_raw
),

active_dates AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    ARRAY_AGG(
      DISTINCT DATE(activity_timestamp, 'UTC')
      ORDER BY DATE(activity_timestamp, 'UTC')
    ) AS active_utc_dates_7d_partial
  FROM
    activity_matches
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

target_addresses AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    ARRAY_AGG(
      DISTINCT activity_to_address
      ORDER BY activity_to_address
    ) AS target_addresses_7d_partial
  FROM
    activity_matches
  WHERE
    activity_to_address IS NOT NULL
  GROUP BY
    claim_transaction_hash,
    claim_log_index
)

SELECT
  scalar.*,
  dates.active_utc_dates_7d_partial,
  IFNULL(
    targets.target_addresses_7d_partial,
    ARRAY<STRING>[]
  ) AS target_addresses_7d_partial
FROM
  scalar_metrics AS scalar
INNER JOIN
  active_dates AS dates
  USING (claim_transaction_hash, claim_log_index)
LEFT JOIN
  target_addresses AS targets
  USING (claim_transaction_hash, claim_log_index);
