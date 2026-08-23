-- Profile and reconcile one compact post-claim activity partial-metrics table.
-- Update the table suffix, source table, source chunk number, and both UTC
-- bounds together. Always dry-run the exact statement before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_01
--     Intended grain is one active exact claim event in source chunk 01.
--   YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_01
--     One successful relevant top-level transaction per unique hash.
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row.
--   YOUR_DATASET_ID.post_claim_transaction_order_batch_*
--     One exact claim transaction per unique transaction hash in each
--     non-overlapping order batch.
--
-- Join keys and expected cardinality:
--   Exact claim event key is (claim_transaction_hash, claim_log_index).
--   Claim transaction hash to compact order key is many-to-one from events.
--   Claim recipient to source from_address is intentionally one-to-many before
--   independent reconciliation aggregation.
--
-- Filters and time boundaries:
--   Source interval is [2023-03-23, 2023-03-27) UTC. Independent activity
--   matching repeats the strict block-aware order and elapsed 24-hour/seven-
--   day half-open filters from SQL 67.
--
-- Row-multiplication risk:
--   Independent expected rows intentionally expand claims to transactions.
--   Stored metrics must remain unique at exact claim-event grain, and aggregate
--   transaction, active-date, and target-pair counts must reconcile exactly.

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
  LEFT JOIN
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
),

expected_activity AS (
  SELECT
    claim.claim_timestamp,
    claim.claim_transaction_hash,
    claim.claim_log_index,
    activity.block_timestamp AS activity_timestamp,
    activity.transaction_hash AS activity_transaction_hash,
    activity.to_address AS activity_to_address
  FROM
    claims_with_order AS claim
  INNER JOIN
    source AS activity
    ON claim.claim_recipient = activity.from_address
  WHERE
    activity.initiated_by_claim_recipient
    AND activity.transaction_hash != claim.claim_transaction_hash
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

partial AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_01`
),

partial_unique_keys AS (
  SELECT
    claim_transaction_hash,
    claim_log_index
  FROM
    partial
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

expected_active_keys AS (
  SELECT
    claim_transaction_hash,
    claim_log_index
  FROM
    expected_activity
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

expected_active_dates AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    DATE(activity_timestamp, 'UTC') AS activity_date
  FROM
    expected_activity
  GROUP BY
    claim_transaction_hash,
    claim_log_index,
    activity_date
),

expected_targets AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    activity_to_address
  FROM
    expected_activity
  WHERE
    activity_to_address IS NOT NULL
  GROUP BY
    claim_transaction_hash,
    claim_log_index,
    activity_to_address
)

SELECT
  (SELECT COUNT(*) FROM partial) AS stored_partial_rows,
  (SELECT COUNT(*) FROM partial_unique_keys) AS distinct_partial_claim_keys,
  (SELECT COUNT(*) FROM partial) - (SELECT COUNT(*) FROM partial_unique_keys)
    AS duplicate_rows_above_partial_claim_grain,
  (SELECT COUNT(*) FROM claims) AS overlapping_claim_events,
  (SELECT COUNT(*) FROM claims_with_order WHERE claim_receipt_timestamp IS NULL)
    AS claims_missing_order_key,
  (SELECT COUNT(*) FROM claims_with_order
    WHERE claim_receipt_timestamp != claim_timestamp)
    AS claim_timestamp_mismatch_rows,
  (SELECT COUNT(*) FROM claims_with_order
    WHERE claim_receipt_block_number != claim_block_number)
    AS claim_block_mismatch_rows,
  (SELECT COUNT(*) FROM expected_active_keys) AS expected_active_claim_events,
  (SELECT COUNT(*) FROM expected_activity) AS expected_activity_rows_7d,
  (SELECT COUNTIF(
    activity_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR)
  ) FROM expected_activity) AS expected_activity_rows_24h,
  (SELECT COALESCE(SUM(successful_transaction_count_7d_partial), 0)
    FROM partial) AS stored_activity_rows_7d,
  (SELECT COALESCE(SUM(successful_transaction_count_24h_partial), 0)
    FROM partial) AS stored_activity_rows_24h,
  (SELECT COUNT(*) FROM expected_active_dates) AS expected_claim_date_pairs_7d,
  (SELECT COALESCE(SUM(ARRAY_LENGTH(active_utc_dates_7d_partial)), 0)
    FROM partial) AS stored_claim_date_pairs_7d,
  (SELECT COUNT(*) FROM expected_targets) AS expected_claim_target_pairs_7d,
  (SELECT COALESCE(SUM(ARRAY_LENGTH(target_addresses_7d_partial)), 0)
    FROM partial) AS stored_claim_target_pairs_7d,
  (SELECT COUNTIF(
    source_chunk_number != 1
    OR claim_timestamp >= TIMESTAMP('2023-03-27 00:00:00+00')
    OR TIMESTAMP_ADD(claim_timestamp, INTERVAL 7 DAY)
      <= TIMESTAMP('2023-03-23 00:00:00+00')
  ) FROM partial) AS rows_outside_expected_chunk_overlap,
  (SELECT COUNTIF(
    source_chunk_number IS NULL
    OR claim_chunk_number IS NULL
    OR claim_timestamp IS NULL
    OR claim_block_number IS NULL
    OR claim_block_hash IS NULL
    OR claim_transaction_hash IS NULL
    OR claim_transaction_index IS NULL
    OR claim_log_index IS NULL
    OR claim_recipient IS NULL
    OR claim_transaction_sender IS NULL
    OR claim_amount_raw IS NULL
    OR active_utc_dates_7d_partial IS NULL
    OR target_addresses_7d_partial IS NULL
  ) FROM partial) AS critical_null_partial_rows,
  (SELECT COUNTIF(
    successful_transaction_count_7d_partial <= 0
    OR successful_transaction_count_24h_partial < 0
    OR successful_transaction_count_24h_partial
      > successful_transaction_count_7d_partial
    OR ARRAY_LENGTH(active_utc_dates_7d_partial) <= 0
    OR ARRAY_LENGTH(active_utc_dates_7d_partial)
      > successful_transaction_count_7d_partial
    OR ARRAY_LENGTH(target_addresses_7d_partial)
      > successful_transaction_count_7d_partial
  ) FROM partial) AS invalid_partial_metric_rows,
  (SELECT COUNTIF(
    first_activity_timestamp_7d_partial IS NULL
    OR first_activity_timestamp_7d_partial < claim_timestamp
    OR first_activity_timestamp_7d_partial
      >= TIMESTAMP_ADD(claim_timestamp, INTERVAL 7 DAY)
    OR (
      successful_transaction_count_24h_partial = 0
      AND first_activity_timestamp_24h_partial IS NOT NULL
    )
    OR (
      successful_transaction_count_24h_partial > 0
      AND (
        first_activity_timestamp_24h_partial IS NULL
        OR first_activity_timestamp_24h_partial < claim_timestamp
        OR first_activity_timestamp_24h_partial
          >= TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR)
      )
    )
  ) FROM partial) AS invalid_first_activity_rows,
  (SELECT COUNT(*) FROM partial AS row
    WHERE ARRAY_LENGTH(row.active_utc_dates_7d_partial) != (
      SELECT COUNT(DISTINCT activity_date)
      FROM UNNEST(row.active_utc_dates_7d_partial) AS activity_date
    )) AS rows_with_duplicate_active_dates,
  (SELECT COUNT(*) FROM partial AS row
    WHERE ARRAY_LENGTH(row.target_addresses_7d_partial) != (
      SELECT COUNT(DISTINCT target_address)
      FROM UNNEST(row.target_addresses_7d_partial) AS target_address
    )) AS rows_with_duplicate_target_addresses,
  (SELECT COUNTIF(
    transaction_hash IS NULL
    OR block_timestamp IS NULL
    OR block_number IS NULL
    OR transaction_index IS NULL
    OR from_address IS NULL
    OR receipt_match_rows != 1
    OR block_match_rows != 1
    OR block_timestamp != matched_block_timestamp
  ) FROM source) AS invalid_source_rows
FROM
  UNNEST([1]);
