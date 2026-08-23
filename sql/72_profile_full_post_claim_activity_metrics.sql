-- Profile and reconcile full-cohort claim-grain post-claim activity metrics.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort
--     Intended grain is one validated claim event and unique recipient.
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row.
--   YOUR_DATASET_ID.post_claim_transaction_order_batch_*
--     One exact claim transaction per unique hash in each order batch.
--   YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_*
--     One active exact claim event per source chunk.
--
-- Join keys and expected cardinality:
--   Exact claim key (claim_transaction_hash, claim_log_index) is one-to-one
--   between final metrics and claims after all partials are aggregated.
--   Claim transaction hash to order key is many-to-one from claim events.
--
-- Filters and time boundaries:
--   Only final two-digit claim and partial suffixes are included. Partials
--   already enforce strict order and half-open elapsed 24-hour/seven-day
--   windows over complete source coverage through 2023-10-02 UTC.
--
-- Row-multiplication risk:
--   Partial rows intentionally repeat exact claim keys across source chunks.
--   This profile independently sums counts and re-deduplicates array values
--   before comparison with the one-row-per-claim final table.

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

order_keys AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_order_batch_*`
),

partial AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

full_metrics AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort`
),

full_unique_keys AS (
  SELECT
    claim_transaction_hash,
    claim_log_index
  FROM
    full_metrics
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

partial_active_dates AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    active_date
  FROM
    partial
  CROSS JOIN
    UNNEST(active_utc_dates_7d_partial) AS active_date
  GROUP BY
    claim_transaction_hash,
    claim_log_index,
    active_date
),

partial_targets AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    target_address
  FROM
    partial
  CROSS JOIN
    UNNEST(target_addresses_7d_partial) AS target_address
  GROUP BY
    claim_transaction_hash,
    claim_log_index,
    target_address
),

metadata_comparison AS (
  SELECT
    metric.claim_transaction_hash,
    metric.claim_log_index,
    claim.claim_transaction_hash IS NULL AS missing_claim,
    order_key.claim_transaction_hash IS NULL AS missing_order_key,
    metric.chunk_number != claim.chunk_number
      OR metric.claim_timestamp != claim.claim_timestamp
      OR metric.claim_block_number != claim.claim_block_number
      OR metric.claim_recipient != claim.claim_recipient
      OR metric.claim_amount_raw != claim.claim_amount_raw
      AS claim_metadata_mismatch,
    metric.claim_block_hash != order_key.claim_block_hash
      OR metric.claim_transaction_index != order_key.claim_transaction_index
      OR metric.claim_transaction_sender != order_key.claim_transaction_sender
      AS order_metadata_mismatch
  FROM
    full_metrics AS metric
  LEFT JOIN
    claims AS claim
    USING (claim_transaction_hash, claim_log_index)
  LEFT JOIN
    order_keys AS order_key
    USING (claim_transaction_hash)
)

SELECT
  (SELECT COUNT(*) FROM full_metrics) AS full_metric_rows,
  (SELECT COUNT(*) FROM full_unique_keys) AS distinct_full_claim_keys,
  (SELECT COUNT(*) FROM full_metrics) - (SELECT COUNT(*) FROM full_unique_keys)
    AS duplicate_rows_above_claim_grain,
  (SELECT COUNT(DISTINCT claim_recipient) FROM full_metrics)
    AS distinct_full_recipients,
  (SELECT COUNT(*) FROM claims) AS expected_claim_events,
  (SELECT COUNT(DISTINCT claim_recipient) FROM claims)
    AS expected_claim_recipients,
  (SELECT COUNT(DISTINCT claim_transaction_hash) FROM claims)
    AS expected_claim_transactions,
  (SELECT SUM(claim_amount_raw) FROM claims) AS expected_claim_amount_raw,
  (SELECT SUM(claim_amount_raw) FROM full_metrics) AS stored_claim_amount_raw,
  (SELECT COUNTIF(missing_claim) FROM metadata_comparison)
    AS metric_rows_missing_claim,
  (SELECT COUNTIF(missing_order_key) FROM metadata_comparison)
    AS metric_rows_missing_order_key,
  (SELECT COUNTIF(claim_metadata_mismatch) FROM metadata_comparison)
    AS claim_metadata_mismatch_rows,
  (SELECT COUNTIF(order_metadata_mismatch) FROM metadata_comparison)
    AS order_metadata_mismatch_rows,
  (SELECT COUNTIF(
    chunk_number IS NULL
    OR claim_timestamp IS NULL
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
  ) FROM full_metrics) AS critical_null_metric_rows,
  (SELECT COUNTIF(
    successful_transaction_count_24h < 0
    OR successful_transaction_count_7d < 0
    OR successful_transaction_count_24h > successful_transaction_count_7d
    OR active_utc_day_count_7d < 0
    OR distinct_target_count_7d < 0
    OR active_utc_day_count_7d > successful_transaction_count_7d
    OR distinct_target_count_7d > successful_transaction_count_7d
  ) FROM full_metrics) AS invalid_metric_value_rows,
  (SELECT COUNTIF(
    (
      successful_transaction_count_24h = 0
      AND (
        first_activity_timestamp_24h IS NOT NULL
        OR seconds_to_first_activity_24h IS NOT NULL
      )
    )
    OR (
      successful_transaction_count_24h > 0
      AND (
        first_activity_timestamp_24h IS NULL
        OR seconds_to_first_activity_24h < 0
        OR seconds_to_first_activity_24h >= 86400
      )
    )
    OR (
      successful_transaction_count_7d = 0
      AND (
        first_activity_timestamp_7d IS NOT NULL
        OR seconds_to_first_activity_7d IS NOT NULL
        OR active_utc_day_count_7d != 0
        OR distinct_target_count_7d != 0
      )
    )
    OR (
      successful_transaction_count_7d > 0
      AND (
        first_activity_timestamp_7d IS NULL
        OR seconds_to_first_activity_7d < 0
        OR seconds_to_first_activity_7d >= 604800
        OR active_utc_day_count_7d <= 0
      )
    )
  ) FROM full_metrics) AS invalid_first_activity_rows,
  (SELECT COUNTIF(successful_transaction_count_24h > 0) FROM full_metrics)
    AS active_recipient_count_24h,
  (SELECT COUNTIF(successful_transaction_count_7d > 0) FROM full_metrics)
    AS active_recipient_count_7d,
  (SELECT SUM(successful_transaction_count_24h) FROM full_metrics)
    AS stored_activity_rows_24h,
  (SELECT SUM(successful_transaction_count_7d) FROM full_metrics)
    AS stored_activity_rows_7d,
  (SELECT SUM(active_utc_day_count_7d) FROM full_metrics)
    AS stored_claim_date_pairs_7d,
  (SELECT SUM(distinct_target_count_7d) FROM full_metrics)
    AS stored_claim_target_pairs_7d,
  (SELECT SUM(successful_transaction_count_24h_partial) FROM partial)
    AS expected_activity_rows_24h_from_partials,
  (SELECT SUM(successful_transaction_count_7d_partial) FROM partial)
    AS expected_activity_rows_7d_from_partials,
  (SELECT COUNT(*) FROM partial_active_dates)
    AS expected_claim_date_pairs_7d_from_partials,
  (SELECT COUNT(*) FROM partial_targets)
    AS expected_claim_target_pairs_7d_from_partials,
  (SELECT COUNTIF(chunk_number = 21) FROM full_metrics)
    AS bounded_chunk_21_claim_rows,
  (SELECT COUNTIF(
    chunk_number = 21 AND successful_transaction_count_24h > 0
  ) FROM full_metrics) AS bounded_chunk_21_active_recipients_24h,
  (SELECT COUNTIF(
    chunk_number = 21 AND successful_transaction_count_7d > 0
  ) FROM full_metrics) AS bounded_chunk_21_active_recipients_7d,
  (SELECT SUM(IF(
    chunk_number = 21,
    successful_transaction_count_24h,
    0
  )) FROM full_metrics) AS bounded_chunk_21_activity_rows_24h,
  (SELECT SUM(IF(
    chunk_number = 21,
    successful_transaction_count_7d,
    0
  )) FROM full_metrics) AS bounded_chunk_21_activity_rows_7d
FROM
  UNNEST([1]);

